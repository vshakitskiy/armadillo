import armadillo/shared/ip
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

pub type Peer {
  Peer(socket: Socket, ip: ip.Address, port: Int)
}

pub type Option {
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
  Address(ip.Address)
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
    on_start: fn(ip.Address, Int) -> Nil,
    port: Int,
    ipv6: Bool,
    reuse_address: Bool,
    interface: IpMode,
    receive_buffer: Int,
    send_buffer: Int,
  )
}

pub fn new(
  state state: state,
  handler handler: fn(state, Message(message)) -> Next(state, message),
) -> Builder(state, message) {
  new_with_initialiser(fn(_self) { Ok(initialised(state)) }, handler)
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
    on_start: fn(_address, _port) { Nil },
    port: 0,
    ipv6: False,
    reuse_address: False,
    interface: Loopback,
    receive_buffer: 10 * 1024 * 1024,
    send_buffer: 10 * 1024 * 1024,
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
    "localhost", _parsed | "127.0.0.1", _parsed -> Loopback
    "0.0.0.0", _parsed -> Any
    _interface, Ok(address) -> Address(address)
    _interface, Error(_nil) -> panic as "Invalid interface provided"
  }

  Builder(..builder, interface: address)
}

@external(erlang, "udp_ffi", "parse_address")
fn parse_address(value: charlist.Charlist) -> Result(ip.Address, Nil)

pub fn with_ipv6(builder: Builder(state, message)) -> Builder(state, message) {
  Builder(..builder, ipv6: True)
}

pub fn reuse_address(
  builder: Builder(state, message),
) -> Builder(state, message) {
  Builder(..builder, reuse_address: True)
}

pub fn receive_buffer(
  builder: Builder(state, message),
  size: Int,
) -> Builder(state, message) {
  Builder(..builder, receive_buffer: size)
}

pub fn send_buffer(
  builder: Builder(state, message),
  size: Int,
) -> Builder(state, message) {
  Builder(..builder, send_buffer: size)
}

pub fn named(
  builder: Builder(state, message),
  name: process.Name(Message(message)),
) -> Builder(state, message) {
  Builder(..builder, name: option.Some(name))
}

pub fn on_start(
  builder: Builder(state, message),
  callback: fn(ip.Address, Int) -> Nil,
) -> Builder(state, message) {
  Builder(..builder, on_start: callback)
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
  let actor_builder =
    actor.new_with_initialiser(1000, fn(_self) {
      let user_subject = process.new_subject()

      let options = udp_settings(builder)

      case open(builder.port, options) {
        Ok(socket) -> {
          case sockname(socket) {
            Ok(#(address, port)) -> builder.on_start(address, port)
            Error(_socket_error) -> Nil
          }

          use Initialised(state, user_selector) <- result.try(
            builder.initialise(user_subject),
          )

          let selector =
            process.new_selector()
            |> process.select(user_subject)
            |> process.map_selector(User)
            |> process.merge_selector(udp_selector())

          actor.initialised(State(socket:, user: state, selector:))
          |> actor.selecting(case user_selector {
            option.Some(user) ->
              process.map_selector(user, User)
              |> process.merge_selector(selector)
            option.None -> selector
          })
          |> actor.returning(user_subject)
          |> Ok
        }
        Error(reason) ->
          Error("Failed to open udp socket. " <> describe_error(reason))
      }
    })
    |> actor.on_message(fn(state, message) {
      let next = exception.rescue(fn() { builder.handler(state.user, message) })

      case next, message {
        Ok(Continue(user, selector)), User(..) ->
          continue_actor(state, user, selector)
        Ok(Continue(user, selector)), Packet(..) -> {
          case set_active(state.socket) {
            Ok(Nil) -> continue_actor(state, user, selector)
            Error(reason) ->
              actor.stop_abnormal(
                "Failed to set udp socket as active. " <> describe_error(reason),
              )
          }
        }
        Ok(NormalStop), _message -> actor.stop()
        Ok(AbnormalStop(reason)), _message -> actor.stop_abnormal(reason)
        Error(reason), _message -> {
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

  let actor_builder = case builder.name {
    option.Some(name) -> actor.named(actor_builder, name)
    option.None -> actor_builder
  }

  actor.start(actor_builder)
}

fn continue_actor(
  state: State(state, message),
  user: state,
  selector: option.Option(process.Selector(message)),
) -> actor.Next(State(state, message), Message(message)) {
  let next = actor.continue(State(..state, user:))

  case selector {
    option.Some(selector) ->
      process.map_selector(selector, User)
      |> process.merge_selector(state.selector)
      |> actor.with_selector(next, _)
    option.None -> next
  }
}

pub fn supervised(
  builder: Builder(state, message),
) -> supervision.ChildSpecification(process.Subject(message)) {
  supervision.worker(fn() { start(builder) })
}

fn udp_settings(builder: Builder(state, message)) -> List(Option) {
  let interface = case builder.interface, builder.ipv6 {
    Loopback, False -> Address(ip.V4(ip.Ipv4(127, 0, 0, 1)))
    Loopback, True -> Address(ip.V6(ip.Ipv6(0, 0, 0, 0, 0, 0, 0, 1)))
    Any, False -> Address(ip.V4(ip.Ipv4(0, 0, 0, 0)))
    Any, True -> Address(ip.V6(ip.Ipv6(0, 0, 0, 0, 0, 0, 0, 0)))
    Address(_ip) as address, _ipv6 -> address
  }

  let options = [
    Ip(interface),
    ReceiveBuffer(builder.receive_buffer),
    SendBuffer(builder.send_buffer),
    ActiveMode(Once),
  ]

  let options = case builder.ipv6 {
    True -> [Ipv6, Ipv6Only(False), ..options]
    False -> options
  }

  case builder.reuse_address {
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
  ip: ip.Address,
  port: Int,
  data: BitArray,
) -> Result(Nil, SocketError)

@external(erlang, "udp_ffi", "open_udp")
pub fn open(port: Int, options: List(Option)) -> Result(Socket, SocketError)

@external(erlang, "udp_ffi", "recv_udp")
pub fn recv(
  socket: Socket,
  timeout: Int,
) -> Result(#(Peer, BitArray), SocketError)

@external(erlang, "udp_ffi", "close_udp")
pub fn close(socket: Socket) -> Nil

@external(erlang, "udp_ffi", "set_active")
pub fn set_active(socket: Socket) -> Result(Nil, SocketError)

@external(erlang, "udp_ffi", "sockname")
fn sockname(socket: Socket) -> Result(#(ip.Address, Int), SocketError)

@external(erlang, "udp_ffi", "coerce_socket_message")
fn coerce_socket_message(record: dynamic.Dynamic) -> Message(message)

pub type SocketError {
  NotOwner
  Timeout
  Closed
  BadArgument

  Eaddrinuse
  Eaddrnotavail
  Eafnosupport
  Ealready
  Econnaborted
  Econnrefused
  Econnreset
  Edestaddrreq
  Ehostdown
  Ehostunreach
  Einprogress
  Eisconn
  Emsgsize
  Enetdown
  Enetunreach
  Enopkg
  Enoprotoopt
  Enotconn
  Enotty
  Enotsock
  Eproto
  Eprotonosupport
  Eprototype
  Esocktnosupport
  Etimedout
  Ewouldblock
  Exbadport
  Exbadseq
  Nxdomain

  Eacces
  Eagain
  Ebadf
  Ebadmsg
  Ebusy
  Edeadlk
  Edeadlock
  Edquot
  Eexist
  Efault
  Efbig
  Eftype
  Eintr
  Einval
  Eio
  Eisdir
  Eloop
  Emfile
  Emlink
  Emultihop
  Enametoolong
  Enfile
  Enobufs
  Enodev
  Enolck
  Enolink
  Enoent
  Enomem
  Enospc
  Enosr
  Enostr
  Enosys
  Enotblk
  Enotdir
  Enotsup
  Enxio
  Eopnotsupp
  Eoverflow
  Eperm
  Epipe
  Erange
  Erofs
  Espipe
  Esrch
  Estale
  Etxtbsy
  Exdev
}

pub fn describe_error(error: SocketError) -> String {
  case error {
    NotOwner -> "Socket not owned by the process trying to use it"
    Timeout -> "Operation timed out"
    Closed -> "Socket is closed"
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
