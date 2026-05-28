import exception
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

pub type Socket

pub type IpAddress {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub type Peer {
  Peer(socket: Socket, ip: IpAddress, port: Int)
}

type Option {
  ActiveMode(ActiveMode)
  Ip(IpMode)
  Ipv6
  Ipv6Only(Bool)
  ReceiveBuffer(Int)
  SendBuffer(Int)
  ReuseAddress
}

pub type ActiveMode {
  Once
  Passive
  Active
  Count(Int)
}

pub type IpMode {
  Address(IpAddress)
  Loopback
  Any
}

pub type Next(state, message) {
  Continue(state, option.Option(process.Selector(message)))
  NormalStop
  AbnormalStop(reason: String)
}

pub fn continue(state: state) -> Next(state, message) {
  Continue(state, option.None)
}

pub fn continue_with_selector(
  state: state,
  selector: process.Selector(message),
) -> Next(state, message) {
  Continue(state, option.Some(selector))
}

pub fn stop() -> Next(state, message) {
  NormalStop
}

pub fn stop_abnormal(reason: String) -> Next(state, message) {
  AbnormalStop(reason:)
}

pub opaque type Initialised(state, message) {
  Initialised(state: state, selector: option.Option(process.Selector(message)))
}

pub fn initialised(state: state) -> Initialised(state, message) {
  Initialised(state:, selector: option.None)
}

pub fn selecting(
  initialised: Initialised(state, old_message),
  selector: process.Selector(message),
) -> Initialised(state, message) {
  Initialised(..initialised, selector: option.Some(selector))
}

pub type Builder(state, message) {
  Builder(
    initialise: fn(process.Subject(message)) ->
      Result(Initialised(state, message), String),
    handler: fn(state, Message(message)) -> Next(state, message),
    name: option.Option(process.Name(Message(message))),
    port: Int,
    ipv6: Bool,
    reuseaddr: Bool,
    interface: IpMode,
    recbuf: Int,
    sndbuf: Int,
  )
}

pub fn new(
  state state: state,
  handler handler: fn(state, Message(message)) -> Next(state, message),
) -> Builder(state, message) {
  Builder(
    initialise: fn(_self) { Ok(initialised(state)) },
    handler:,
    name: option.None,
    port: 0,
    ipv6: False,
    reuseaddr: False,
    interface: Loopback,
    recbuf: 10 * 1024 * 1024,
    sndbuf: 10 * 1024 * 1024,
  )
}

pub fn new_with_initialiser(
  initialise initialise: fn(process.Subject(message)) ->
    Result(Initialised(state, message), String),
  handler handler: fn(state, Message(message)) -> Next(state, message),
) -> Builder(state, message) {
  Builder(
    initialise:,
    handler:,
    name: option.None,
    port: 0,
    ipv6: False,
    reuseaddr: False,
    interface: Loopback,
    recbuf: 10 * 1024 * 1024,
    sndbuf: 10 * 1024 * 1024,
  )
}

pub fn port(
  builder: Builder(state, message),
  port: Int,
) -> Builder(state, message) {
  Builder(..builder, port:)
}

pub fn bind(
  builder: Builder(state, message),
  interface: String,
) -> Builder(state, message) {
  let address = case interface, parse_address(charlist.from_string(interface)) {
    "localhost", _ | "127.0.0.1", _ -> Loopback
    "0.0.0.0", _ -> Any
    _, Ok(address) -> Address(address)
    _, Error(_nil) -> panic as "Invalid interface provided"
  }

  Builder(..builder, interface: address)
}

@external(erlang, "udp_ffi", "parse_address")
fn parse_address(value: charlist.Charlist) -> Result(ip_address, Nil)

pub fn with_ipv6(builder: Builder(state, message)) -> Builder(state, message) {
  Builder(..builder, ipv6: True)
}

pub fn reuse_address(
  builder: Builder(state, message),
) -> Builder(state, message) {
  Builder(..builder, reuseaddr: True)
}

pub fn receive_buffer(
  builder: Builder(state, message),
  size: Int,
) -> Builder(state, message) {
  Builder(..builder, recbuf: size)
}

pub fn send_buffer(
  builder: Builder(state, message),
  size: Int,
) -> Builder(state, message) {
  Builder(..builder, sndbuf: size)
}

pub fn named(
  builder: Builder(state, message),
  name: process.Name(Message(message)),
) -> Builder(state, message) {
  Builder(..builder, name: option.Some(name))
}

type State(state, message) {
  State(
    socket: Socket,
    user: state,
    selector: process.Selector(Message(message)),
  )
}

pub type Message(message) {
  Packet(peer: Peer, data: BitArray)
  User(message)
}

pub fn start(
  builder: Builder(state, message),
) -> actor.StartResult(process.Subject(message)) {
  let actor =
    actor.new_with_initialiser(1000, fn(_self) {
      let user = process.new_subject()

      let options = udp_settings(builder)

      case open_udp(builder.port, options) {
        Ok(socket) -> {
          use Initialised(state, user_selector) <- result.try(
            builder.initialise(user),
          )

          let selector =
            process.new_selector()
            |> process.select(user)
            |> process.map_selector(User)
            |> process.merge_selector(udp_selector())

          actor.initialised(State(socket:, user: state, selector:))
          |> actor.selecting(case user_selector {
            option.Some(user) ->
              process.map_selector(user, User)
              |> process.merge_selector(selector)
            option.None -> selector
          })
          |> actor.returning(user)
          |> Ok
        }
        Error(reason) ->
          Error("Failed to open udp socket. " <> describe_error(reason))
      }
    })
    |> actor.on_message(fn(state, message) {
      let next = exception.rescue(fn() { builder.handler(state.user, message) })

      case next, message {
        Ok(Continue(user, selector)), User(..) -> {
          let next = actor.continue(State(..state, user:))
          case selector {
            option.Some(selector) -> {
              process.map_selector(selector, User)
              |> process.merge_selector(state.selector)
              |> actor.with_selector(next, _)
            }
            option.None -> next
          }
        }
        Ok(Continue(user, selector)), Packet(..) -> {
          case set_active(state.socket) {
            Ok(Nil) -> {
              let next = actor.continue(State(..state, user:))
              case selector {
                option.Some(selector) -> {
                  process.map_selector(selector, User)
                  |> process.merge_selector(state.selector)
                  |> actor.with_selector(next, _)
                }
                option.None -> next
              }
            }
            Error(reason) ->
              actor.stop_abnormal(
                "Failed to set udp socket as active. " <> describe_error(reason),
              )
          }
        }
        Ok(NormalStop), _ -> actor.stop()
        Ok(AbnormalStop(reason)), _ -> actor.stop_abnormal(reason)
        Error(reason), _ -> {
          let reason = case reason {
            exception.Errored(_dynamic) ->
              "An error was raised in the handler. This can be caused by calling the erlang:error/1 function, or some other runtime error."
            exception.Thrown(_dynamic) ->
              "A value was thrown in the handler. This can be caused by calling the erlang:throw/1 function."
            exception.Exited(_dynamic) ->
              "A process exited in the handler. This can be caused by calling the erlang:exit/1 function."
          }
          actor.stop_abnormal(reason)
        }
      }
    })

  let actor = case builder.name {
    option.Some(name) -> actor.named(actor, name)
    option.None -> actor
  }

  actor.start(actor)
}

pub fn supervised(
  builder: Builder(state, message),
) -> supervision.ChildSpecification(process.Subject(message)) {
  supervision.worker(fn() { start(builder) })
}

fn udp_settings(builder: Builder(state, message)) -> List(Option) {
  let interface = case builder.interface, builder.ipv6 {
    Loopback, False -> Address(IpV4(127, 0, 0, 1))
    Loopback, True -> Address(IpV6(0, 0, 0, 0, 0, 0, 0, 1))
    Any, False -> Address(IpV4(0, 0, 0, 0))
    Any, True -> Address(IpV6(0, 0, 0, 0, 0, 0, 0, 0))
    other, _ -> other
  }

  let options = [
    Ip(interface),
    ReceiveBuffer(builder.recbuf),
    SendBuffer(builder.sndbuf),
    ActiveMode(Once),
  ]

  let options = case builder.ipv6 {
    True -> [Ipv6, Ipv6Only(False), ..options]
    False -> options
  }

  case builder.reuseaddr {
    True -> [ReuseAddress, ..options]
    False -> options
  }
}

fn udp_selector() -> process.Selector(Message(message)) {
  process.new_selector()
  |> process.select_record(atom.create("udp"), 4, coerce_socket_message)
}

pub fn send(peer: Peer, data: BitArray) -> Result(Nil, SocketError) {
  send_udp(peer.socket, peer.ip, peer.port, data)
}

@external(erlang, "udp_ffi", "send_udp")
fn send_udp(
  socket: Socket,
  ip: IpAddress,
  port: Int,
  data: BitArray,
) -> Result(Nil, SocketError)

@external(erlang, "udp_ffi", "open_udp")
fn open_udp(port: Int, options: List(Option)) -> Result(Socket, SocketError)

@external(erlang, "udp_ffi", "set_active")
fn set_active(socket: Socket) -> Result(Nil, SocketError)

@external(erlang, "udp_ffi", "coerce_socket_message")
fn coerce_socket_message(record: dynamic.Dynamic) -> Message(message)

pub type SocketError {
  /// Socket not owned by the process trying to use it.
  /// This is documented as an error value in the
  /// [`gen_udp` documentation](https://www.erlang.org/doc/apps/kernel/gen_udp.html),
  /// but it's unclear how to trigger it.
  NotOwner
  /// Operation timed out
  Timeout
  /// gen_udp threw a bad argument exception. Probably an invalid port number.
  BadArgument

  // https://www.erlang.org/doc/maninet#type-posix
  /// Address already in use
  Eaddrinuse
  /// Cannot assign requested address
  Eaddrnotavail
  /// Address family not supported
  Eafnosupport
  /// Operation already in progress
  Ealready
  /// Connection aborted
  Econnaborted
  /// Connection refused
  Econnrefused
  /// Connection reset by peer
  Econnreset
  /// Destination address required
  Edestaddrreq
  /// Host is down
  Ehostdown
  /// No route to host
  Ehostunreach
  /// Operation now in progress
  Einprogress
  /// Socket is already connected
  Eisconn
  /// Message too long
  Emsgsize
  /// Network is down
  Enetdown
  /// Network is unreachable
  Enetunreach
  /// Package not installed
  Enopkg
  /// Protocol not available
  Enoprotoopt
  /// Socket is not connected
  Enotconn
  /// Inappropriate ioctl for device
  Enotty
  /// Socket operation on non-socket
  Enotsock
  /// Protocol error
  Eproto
  /// Protocol not supported
  Eprotonosupport
  /// Protocol wrong type for socket
  Eprototype
  /// Socket type not supported
  Esocktnosupport
  /// Connection timed out
  Etimedout
  /// Operation would block
  Ewouldblock
  /// Bad port number
  Exbadport
  /// Bad sequence number
  Exbadseq
  /// Non-existent domain
  Nxdomain

  // https://www.erlang.org/doc/man/file#type-posix
  /// Permission denied
  Eacces
  /// Resource temporarily unavailable
  Eagain
  /// Bad file descriptor
  Ebadf
  /// Bad message
  Ebadmsg
  /// Device or resource busy
  Ebusy
  /// Resource deadlock avoided
  Edeadlk
  /// Resource deadlock avoided
  Edeadlock
  /// Disk quota exceeded
  Edquot
  /// File exists
  Eexist
  /// Bad address
  Efault
  /// File too large
  Efbig
  /// Inappropriate file type or format
  Eftype
  /// Interrupted system call
  Eintr
  /// Invalid argument
  Einval
  /// Input/output error
  Eio
  /// Is a directory
  Eisdir
  /// Too many levels of symbolic links
  Eloop
  /// Too many open files
  Emfile
  /// Too many links
  Emlink
  /// Multihop attempted
  Emultihop
  /// File name too long
  Enametoolong
  /// Too many open files in system
  Enfile
  /// No buffer space available
  Enobufs
  /// No such device
  Enodev
  /// No locks available
  Enolck
  /// Link has been severed
  Enolink
  /// No such file or directory
  Enoent
  /// Out of memory
  Enomem
  /// No space left on device
  Enospc
  /// Out of streams resources
  Enosr
  /// Device not a stream
  Enostr
  /// Function not implemented
  Enosys
  /// Block device required
  Enotblk
  /// Not a directory
  Enotdir
  /// Operation not supported
  Enotsup
  /// No such device or address
  Enxio
  /// Operation not supported on socket
  Eopnotsupp
  /// Value too large for defined data type
  Eoverflow
  /// Operation not permitted
  Eperm
  /// Broken pipe
  Epipe
  /// Result too large
  Erange
  /// Read-only file system
  Erofs
  /// Illegal seek
  Espipe
  /// No such process
  Esrch
  /// Stale file handle
  Estale
  /// Text file busy
  Etxtbsy
  /// Cross-device link
  Exdev
}

pub fn describe_error(error: SocketError) -> String {
  case error {
    NotOwner -> "Socket not owned by the process trying to use it"
    Timeout -> "Operation timed out"
    BadArgument -> "Bad argument (probably invalid port number)"
    Eaddrinuse -> "Address already in use"
    Eaddrnotavail -> "Cannot assign requested address"
    Eafnosupport -> "Address family not supported"
    Ealready -> "Operation already in progress"
    Econnaborted -> "Connection aborted"
    Econnrefused -> "Connection refused"
    Econnreset -> "Connection reset by peer"
    Edestaddrreq -> "Destination address required"
    Ehostdown -> "Host is down"
    Ehostunreach -> "No route to host"
    Einprogress -> "Operation now in progress"
    Eisconn -> "Socket is already connected"
    Emsgsize -> "Message too long"
    Enetdown -> "Network is down"
    Enetunreach -> "Network is unreachable"
    Enopkg -> "Package not installed"
    Enoprotoopt -> "Protocol not available"
    Enotconn -> "Socket is not connected"
    Enotty -> "Inappropriate ioctl for device"
    Enotsock -> "Socket operation on non-socket"
    Eproto -> "Protocol error"
    Eprotonosupport -> "Protocol not supported"
    Eprototype -> "Protocol wrong type for socket"
    Esocktnosupport -> "Socket type not supported"
    Etimedout -> "Connection timed out"
    Ewouldblock -> "Operation would block"
    Exbadport -> "Bad port number"
    Exbadseq -> "Bad sequence number"
    Nxdomain -> "Non-existent domain"
    Eacces -> "Permission denied"
    Eagain -> "Resource temporarily unavailable"
    Ebadf -> "Bad file descriptor"
    Ebadmsg -> "Bad message"
    Ebusy -> "Device or resource busy"
    Edeadlk -> "Resource deadlock avoided"
    Edeadlock -> "Resource deadlock avoided"
    Edquot -> "Disk quota exceeded"
    Eexist -> "File exists"
    Efault -> "Bad address"
    Efbig -> "File too large"
    Eftype -> "Inappropriate file type or format"
    Eintr -> "Interrupted system call"
    Einval -> "Invalid argument"
    Eio -> "Input/output error"
    Eisdir -> "Is a directory"
    Eloop -> "Too many levels of symbolic links"
    Emfile -> "Too many open files"
    Emlink -> "Too many links"
    Emultihop -> "Multihop attempted"
    Enametoolong -> "File name too long"
    Enfile -> "Too many open files in system"
    Enobufs -> "No buffer space available"
    Enodev -> "No such device"
    Enolck -> "No locks available"
    Enolink -> "Link has been severed"
    Enoent -> "No such file or directory"
    Enomem -> "Out of memory"
    Enospc -> "No space left on device"
    Enosr -> "Out of streams resources"
    Enostr -> "Device not a stream"
    Enosys -> "Function not implemented"
    Enotblk -> "Block device required"
    Enotdir -> "Not a directory"
    Enotsup -> "Operation not supported"
    Enxio -> "No such device or address"
    Eopnotsupp -> "Operation not supported on socket"
    Eoverflow -> "Value too large for defined data type"
    Eperm -> "Operation not permitted"
    Epipe -> "Broken pipe"
    Erange -> "Result too large"
    Erofs -> "Read-only file system"
    Espipe -> "Illegal seek"
    Esrch -> "No such process"
    Estale -> "Stale file handle"
    Etxtbsy -> "Text file busy"
    Exdev -> "Cross-device link"
  }
}
