import formal/form
import gleam/dynamic/decode
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/pair
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/element/svg
import lustre/event
import rsvp
import shared/ip
import shared/records

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

type Model {
  Model(
    records: List(records.Record),
    loading: Bool,
    saving: Bool,
    error: option.Option(String),
    popup: Popup,
    deleting: option.Option(#(String, records.RecordType)),
  )
}

type Popup {
  Hidden
  Visible(PopupContent)
  Closing(PopupContent)
}

type PopupContent {
  InsertContent(type_: records.RecordType, form: form.Form(records.Record))
  UpdateContent(record: records.Record, form: form.Form(records.Record))
}

fn init(_args: Nil) -> #(Model, effect.Effect(Message)) {
  Model(
    records: [],
    loading: True,
    saving: False,
    error: option.None,
    popup: Hidden,
    deleting: option.None,
  )
  |> pair.new(fetch_records(ApiFetchReturned))
}

fn new_a_insert_form() -> form.Form(records.Record) {
  form.new({
    use name <- form.field("name", form.parse_string |> form.check_not_empty)
    use value <- form.field("value", parse_ipv4())
    use ttl <- form.field("ttl", parse_ttl())

    form.success(records.ARecord(name:, ttl:, ip: value))
  })
  |> form.add_string("ttl", "300")
}

fn new_aaaa_insert_form() -> form.Form(records.Record) {
  form.new({
    use name <- form.field("name", form.parse_string |> form.check_not_empty)
    use value <- form.field("value", parse_ipv6())
    use ttl <- form.field("ttl", parse_ttl())

    form.success(records.AaaaRecord(name:, ttl:, ip: value))
  })
  |> form.add_string("ttl", "300")
}

fn new_cname_insert_form() -> form.Form(records.Record) {
  form.new({
    use name <- form.field("name", form.parse_string |> form.check_not_empty)
    use value <- form.field("value", form.parse_string |> form.check_not_empty)
    use ttl <- form.field("ttl", parse_ttl())

    form.success(records.CnameRecord(name:, ttl:, target: value))
  })
  |> form.add_string("ttl", "300")
}

fn new_insert_form_for(type_: records.RecordType) -> form.Form(records.Record) {
  case type_ {
    records.A -> new_a_insert_form()
    records.Aaaa -> new_aaaa_insert_form()
    records.Cname -> new_cname_insert_form()
  }
}

fn new_update_form(record: records.Record) -> form.Form(records.Record) {
  case record {
    records.ARecord(name:, ttl:, ip: addr) ->
      form.new({
        use value <- form.field("value", parse_ipv4())
        use new_ttl <- form.field("ttl", parse_ttl())

        form.success(records.ARecord(name:, ttl: new_ttl, ip: value))
      })
      |> form.add_string("value", ip.ipv4_to_string(addr))
      |> form.add_string("ttl", int.to_string(ttl))

    records.AaaaRecord(name:, ttl:, ip: addr) ->
      form.new({
        use value <- form.field("value", parse_ipv6())
        use new_ttl <- form.field("ttl", parse_ttl())

        form.success(records.AaaaRecord(name:, ttl: new_ttl, ip: value))
      })
      |> form.add_string("value", ip.ipv6_to_string(addr))
      |> form.add_string("ttl", int.to_string(ttl))

    records.CnameRecord(name:, ttl:, target:) ->
      form.new({
        use value <- form.field(
          "value",
          form.parse_string |> form.check_not_empty,
        )
        use new_ttl <- form.field("ttl", parse_ttl())

        form.success(records.CnameRecord(name:, ttl: new_ttl, target: value))
      })
      |> form.add_string("value", target)
      |> form.add_string("ttl", int.to_string(ttl))
  }
}

fn parse_ipv4() {
  let blank = ip.Ipv4(0, 0, 0, 0)

  use values <- form.parse
  case values {
    ["", ..] -> Error(#(blank, "must not be blank"))
    [value, ..] ->
      case ip.ipv4_from_string(value) {
        Ok(parsed) -> Ok(parsed)
        Error(Nil) -> Error(#(blank, "must be a valid IPv4 address"))
      }
    _ -> Error(#(blank, "must not be blank"))
  }
}

fn parse_ipv6() {
  let blank = ip.Ipv6(0, 0, 0, 0, 0, 0, 0, 0)

  use values <- form.parse
  case values {
    ["", ..] -> Error(#(blank, "must not be blank"))
    [value, ..] ->
      case ip.ipv6_from_string(value) {
        Ok(parsed) -> Ok(parsed)
        Error(Nil) -> Error(#(blank, "must be a valid IPv6 address"))
      }
    _ -> Error(#(blank, "must not be blank"))
  }
}

fn parse_ttl() {
  use values <- form.parse
  case values {
    ["", ..] -> Error(#(0, "must not be blank"))
    [value, ..] ->
      case int.parse(value) {
        Ok(number) if number > 0 -> Ok(number)
        Ok(_) -> Error(#(0, "must be a positive number"))
        Error(Nil) -> Error(#(0, "must be a number"))
      }
    _ -> Error(#(0, "must not be blank"))
  }
}

fn fetch_records(
  on_response handle_response: fn(
    Result(List(records.Record), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  decode.list(of: records.record_decoder())
  |> rsvp.expect_json(handle_response)
  |> rsvp.get("/api/records", _)
}

fn insert_record(
  record: records.Record,
  on_response handle_response: fn(
    records.Record,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(handle_response(record, _))
  |> rsvp.post("/api/records", records.record_to_json(record), _)
}

fn update_record(
  record: records.Record,
  on_response handle_response: fn(
    records.Record,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(handle_response(record, _))
  |> rsvp.patch("/api/records", records.record_to_json(record), _)
}

fn delete_record(
  name: String,
  type_: records.RecordType,
  on_response handle_response: fn(
    #(String, records.RecordType),
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  let body =
    json.object([
      #("name", json.string(name)),
      #("type", records.record_type_to_json(type_)),
    ])

  rsvp.expect_ok_response(handle_response(#(name, type_), _))
  |> rsvp.delete("/api/records", body, _)
}

type Message {
  ApiFetchReturned(Result(List(records.Record), rsvp.Error(String)))

  UserClosedPopup
  PopupAnimationEnded

  UserClickedInsert
  UserChangedInsertType(records.RecordType)
  UserSubmittedInsertForm(Result(records.Record, form.Form(records.Record)))
  ApiInsertReturned(
    record: records.Record,
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserClickedEdit(current_record: records.Record)
  UserSubmittedUpdateForm(Result(records.Record, form.Form(records.Record)))
  ApiUpdateReturned(
    updated_record: records.Record,
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserClickedDelete(#(String, records.RecordType))
  UserConfirmedDelete(#(String, records.RecordType))
  DeleteCancelled(#(String, records.RecordType))
  ApiDeleteReturned(
    key: #(String, records.RecordType),
    result: Result(response.Response(String), rsvp.Error(String)),
  )
}

@external(javascript, "./timer_ffi.mjs", "set_timeout")
fn set_timeout(callback: fn() -> Nil, ms: Int) -> Nil

fn delete_cancel_after(
  key: #(String, records.RecordType),
  ms: Int,
) -> effect.Effect(Message) {
  use dispatch <- effect.from
  use <- set_timeout(_, ms)

  dispatch(DeleteCancelled(key))
}

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case model, message {
    model, ApiFetchReturned(Ok(records)) -> #(
      Model(..model, records:, loading: False),
      effect.none(),
    )
    model, ApiFetchReturned(Error(_)) -> {
      let error = option.Some("Something went wrong!")
      #(Model(..model, loading: False, error:), effect.none())
    }

    Model(popup: Hidden, ..), UserClosedPopup -> panic as "unreachable!"
    Model(popup: Visible(content), saving: False, ..), UserClosedPopup -> #(
      Model(..model, popup: Closing(content)),
      effect.none(),
    )
    Model(popup: Closing(..), ..), UserClosedPopup -> #(model, effect.none())
    Model(saving: True, ..), UserClosedPopup -> #(model, effect.none())

    Model(popup: Closing(..), ..), PopupAnimationEnded -> #(
      Model(..model, popup: Hidden),
      effect.none(),
    )
    _model, PopupAnimationEnded -> #(model, effect.none())

    Model(popup: Hidden, ..), UserClickedInsert -> {
      let popup = Visible(InsertContent(records.A, new_a_insert_form()))
      #(Model(..model, popup:), effect.none())
    }
    _model, UserClickedInsert -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(_, old_form)), ..),
      UserChangedInsertType(new_type)
    -> {
      let name = form.field_value(old_form, "name")
      let ttl = form.field_value(old_form, "ttl")

      let new_form =
        new_insert_form_for(new_type)
        |> form.add_string("name", name)
        |> form.add_string("ttl", ttl)

      let popup = Visible(InsertContent(new_type, new_form))
      #(Model(..model, popup:), effect.none())
    }
    _model, UserChangedInsertType(_) -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(..)), ..),
      UserSubmittedInsertForm(Ok(record))
    -> #(Model(..model, saving: True), insert_record(record, ApiInsertReturned))
    Model(popup: Visible(InsertContent(type_, ..)), ..),
      UserSubmittedInsertForm(Error(form))
    -> {
      let popup = Visible(InsertContent(type_, form))
      #(Model(..model, popup:), effect.none())
    }
    _model, UserSubmittedInsertForm(_) -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(..)), ..),
      ApiInsertReturned(record:, result: Ok(_))
    -> {
      let records = list.append(model.records, [record])
      #(Model(..model, records:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Visible(InsertContent(..)), ..),
      ApiInsertReturned(record: _, result: Error(_))
    -> {
      let error = option.Some("Something went wrong inserting record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
    Model(..), ApiInsertReturned(..) -> panic as "unreachable!"

    Model(popup: Hidden, ..), UserClickedEdit(current_record:) -> {
      let popup =
        Visible(UpdateContent(current_record, new_update_form(current_record)))
      #(Model(..model, popup:), effect.none())
    }
    _model, UserClickedEdit(..) -> panic as "unreachable!"

    Model(popup: Visible(UpdateContent(..)), ..),
      UserSubmittedUpdateForm(Ok(record))
    -> #(Model(..model, saving: True), update_record(record, ApiUpdateReturned))
    Model(popup: Visible(UpdateContent(original, ..)), ..),
      UserSubmittedUpdateForm(Error(form))
    -> #(
      Model(..model, popup: Visible(UpdateContent(original, form))),
      effect.none(),
    )
    _model, UserSubmittedUpdateForm(_) -> panic as "unreachable!"

    Model(popup: Visible(UpdateContent(..)), ..),
      ApiUpdateReturned(updated_record:, result: Ok(_))
    -> {
      let records =
        list.map(model.records, fn(record) {
          case record, updated_record {
            records.ARecord(name: a, ..), records.ARecord(name: b, ..)
            | records.AaaaRecord(name: a, ..), records.AaaaRecord(name: b, ..)
            | records.CnameRecord(name: a, ..), records.CnameRecord(name: b, ..)
              if a == b
            -> updated_record
            _, _ -> record
          }
        })

      #(Model(..model, records:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Visible(UpdateContent(..)), ..),
      ApiUpdateReturned(updated_record: _, result: Error(_))
    -> {
      let error = option.Some("Something went wrong updating record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
    Model(..), ApiUpdateReturned(..) -> panic as "unreachable!"

    model, UserClickedDelete(key) -> #(
      Model(..model, deleting: option.Some(key)),
      delete_cancel_after(key, 3000),
    )

    model, DeleteCancelled(key) ->
      case model.deleting {
        option.Some(pending) if pending == key -> #(
          Model(..model, deleting: option.None),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    model, UserConfirmedDelete(key) -> {
      let #(target, type_) = key

      Model(..model, saving: True, deleting: option.None)
      |> pair.new(delete_record(target, type_, ApiDeleteReturned))
    }

    model, ApiDeleteReturned(key:, result: Ok(_)) -> {
      let #(target, type_) = key

      let records =
        list.filter(model.records, fn(record) {
          case record, type_ {
            records.ARecord(name:, ..), records.A
            | records.AaaaRecord(name:, ..), records.Aaaa
            | records.CnameRecord(name:, ..), records.Cname
            -> name != target
            _, _ -> True
          }
        })

      #(Model(..model, records:, saving: False), effect.none())
    }
    model, ApiDeleteReturned(key: _, result: Error(_)) -> {
      let error = option.Some("Something went wrong deleting record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
  }
}

fn view(model: Model) -> Element(Message) {
  let global_busy = model.saving || model.popup != Hidden

  html.div([attribute.class("min-h-screen bg-bg text-fg")], [
    case model.popup {
      Hidden -> element.none()
      Visible(content) -> view_popup(content, False, model.saving)
      Closing(content) -> view_popup(content, True, model.saving)
    },
    html.div(
      [
        attribute.class(
          "w-full max-w-sm xs:max-w-lg sm:max-w-2xl md:max-w-3xl lg:max-w-5xl xl:max-w-6xl mx-auto px-2 py-3 xs:px-5 xs:py-6 sm:px-9 sm:py-9 md:px-12 md:py-12 lg:px-16 lg:py-14",
        ),
      ],
      [
        case model.error {
          option.Some(message) ->
            html.p(
              [
                attribute.class(
                  "text-red-400 text-xs sm:text-base md:text-lg mb-3 sm:mb-5 bg-red-950 p-2 italic",
                ),
              ],
              [html.text(message)],
            )
          option.None -> element.none()
        },
        view_header(),
        case model.loading {
          True ->
            html.p(
              [
                attribute.class(
                  "text-subtle text-xs xs:text-base sm:text-lg md:text-xl italic",
                ),
              ],
              [html.text("Loading...")],
            )
          False ->
            html.table([attribute.class("w-full border-collapse")], [
              html.thead([], [
                html.tr([], [
                  view_th("domain"),
                  view_th("type"),
                  view_th("value"),
                  view_th("ttl"),
                  html.th(
                    [
                      attribute.class(
                        "w-fit pb-1 xs:pb-3 sm:pb-4 md:pb-5 border-b border-elevated",
                      ),
                    ],
                    [],
                  ),
                ]),
              ]),
              keyed.tbody(
                [],
                list.map(model.records, view_record(
                  model.deleting,
                  global_busy,
                  _,
                )),
              ),
            ])
        },
      ],
    ),
  ])
}

fn view_header() -> Element(Message) {
  html.header(
    [
      attribute.class(
        "flex items-center mb-3 xs:mb-6 sm:mb-10 md:mb-12 lg:mb-14",
      ),
    ],
    [
      html.div(
        [
          attribute.class(
            "bg-fg rounded-full size-6 xs:size-9 sm:size-12 md:size-14 lg:size-16 mr-2 flex items-center justify-center",
          ),
        ],
        [
          html.img([
            attribute.src("/armadillo.png"),
            attribute.class("size-3 xs:size-5 sm:size-7 md:size-9 lg:size-10"),
          ]),
        ],
      ),
      html.h1(
        [
          attribute.class(
            "text-xs xs:text-lg sm:text-2xl md:text-3xl lg:text-4xl font-semibold tracking-tight mr-2 xs:mr-3 sm:mr-5 lg:mr-6",
          ),
        ],
        [html.text("DNS Records")],
      ),
      html.button(
        [
          event.on_click(UserClickedInsert),
          attribute.class(
            "w-5 h-5 xs:w-7 xs:h-7 sm:w-10 sm:h-10 md:w-11 md:h-11 lg:w-12 lg:h-12 rounded-md bg-accent text-fg flex items-center justify-center hover:bg-accent/80 transition-colors cursor-pointer",
          ),
        ],
        [view_add_icon()],
      ),
    ],
  )
}

fn view_th(label: String) -> Element(Message) {
  html.th(
    [
      attribute.class(
        "text-left text-2xs xs:text-xs sm:text-sm md:text-base uppercase tracking-wider text-subtle pb-1 xs:pb-3 sm:pb-4 md:pb-5 border-b border-elevated font-medium italic",
      ),
    ],
    [html.text(label)],
  )
}

fn view_popup(
  content: PopupContent,
  closing: Bool,
  saving: Bool,
) -> element.Element(Message) {
  let #(overlay_class, card_class) = case closing {
    True -> #("overlay-exit", "popup-exit")
    False -> #("overlay-enter", "popup-enter")
  }

  html.div(
    [
      attribute.class(
        "fixed z-1 size-full flex items-center justify-center " <> overlay_class,
      ),
      attribute.id("popup-overlay"),
      event.on("click", {
        use id <- decode.field("target", {
          use id <- decode.field("id", decode.string)
          decode.success(id)
        })

        case id {
          "popup-overlay" -> decode.success(UserClosedPopup)
          _ -> decode.failure(UserClosedPopup, "")
        }
      }),
    ],
    [
      html.div(
        [
          attribute.class(
            "bg-surface border border-elevated rounded-xl p-3 xs:p-5 sm:p-8 md:p-10 lg:p-12 w-[calc(100vw-3rem)] max-w-xs xs:max-w-sm sm:max-w-md md:max-w-lg lg:max-w-xl xl:max-w-2xl shadow-2xl "
            <> card_class,
          ),
          event.on("animationend", decode.success(PopupAnimationEnded)),
        ],
        [
          case content {
            InsertContent(type_, form) -> view_insert(type_, form, saving)
            UpdateContent(record, form) -> view_update(record, form, saving)
          },
        ],
      ),
    ],
  )
}

fn view_insert(
  type_: records.RecordType,
  form: form.Form(records.Record),
  saving: Bool,
) -> element.Element(Message) {
  let handle_submit = fn(values) {
    form.add_values(form, values) |> form.run |> UserSubmittedInsertForm
  }

  let value_label = case type_ {
    records.A -> "IPv4 Address"
    records.Aaaa -> "IPv6 Address"
    records.Cname -> "Target"
  }

  html.form([event.on_submit(handle_submit), attribute.class("flex flex-col")], [
    html.h2(
      [
        attribute.class(
          "text-xs xs:text-base sm:text-xl md:text-2xl font-semibold mb-2 xs:mb-4 sm:mb-6 md:mb-8",
        ),
      ],
      [html.text("Add Record")],
    ),
    html.div([attribute.class("flex gap-2 mb-4")], [
      view_type_button("A", records.A, type_ == records.A),
      view_type_button("AAAA", records.Aaaa, type_ == records.Aaaa),
      view_type_button("CNAME", records.Cname, type_ == records.Cname),
    ]),
    view_input(form, is: "text", name: "name", label: "Domain"),
    view_input(form, is: "text", name: "value", label: value_label),
    view_input(form, is: "number", name: "ttl", label: "TTL (seconds)"),
    html.button(
      [
        attribute.disabled(saving),
        attribute.class(
          "mt-2 xs:mt-4 sm:mt-6 py-1.5 xs:py-3 sm:py-4 md:py-5 rounded-lg text-xs xs:text-sm sm:text-base md:text-lg font-medium w-full "
          <> case saving {
            True -> "bg-accent/50 text-fg/50 cursor-not-allowed"
            False ->
              "bg-accent text-fg hover:bg-accent/80 transition-colors cursor-pointer"
          },
        ),
      ],
      [html.text("Add")],
    ),
  ])
}

fn view_type_button(
  label: String,
  type_: records.RecordType,
  active: Bool,
) -> Element(Message) {
  html.button(
    [
      attribute.type_("button"),
      event.on_click(UserChangedInsertType(type_)),
      attribute.class(
        "px-2 py-1 xs:px-3 xs:py-1.5 sm:px-4 sm:py-2 rounded text-2xs xs:text-xs sm:text-sm font-medium transition-colors cursor-pointer "
        <> case active {
          True -> "bg-accent text-fg"
          False -> "bg-elevated text-subtle hover:text-fg"
        },
      ),
    ],
    [html.text(label)],
  )
}

fn view_update(
  record: records.Record,
  form: form.Form(records.Record),
  saving: Bool,
) -> Element(Message) {
  let handle_submit = fn(values) {
    form.add_values(form, values) |> form.run |> UserSubmittedUpdateForm
  }

  let value_label = case record {
    records.ARecord(..) -> "IPv4 Address"
    records.AaaaRecord(..) -> "IPv6 Address"
    records.CnameRecord(..) -> "Target"
  }

  html.form([event.on_submit(handle_submit), attribute.class("flex flex-col")], [
    html.h2([attribute.class("text-base font-semibold mb-1")], [
      html.text("Edit Record"),
    ]),
    html.p([attribute.class("text-xs text-subtle mb-4 italic")], [
      html.text(record.name),
    ]),
    view_input(form, is: "text", name: "value", label: value_label),
    view_input(form, is: "number", name: "ttl", label: "TTL (seconds)"),
    html.button(
      [
        attribute.disabled(saving),
        attribute.class(
          "mt-2 xs:mt-4 sm:mt-6 py-1.5 xs:py-3 sm:py-4 md:py-5 rounded-lg text-xs xs:text-sm sm:text-base md:text-lg font-medium w-full "
          <> case saving {
            True -> "bg-accent/50 text-fg/50 cursor-not-allowed"
            False ->
              "bg-accent text-fg hover:bg-accent/80 transition-colors cursor-pointer"
          },
        ),
      ],
      [html.text("Update")],
    ),
  ])
}

fn view_input(
  frm: form.Form(data),
  is type_: String,
  name name: String,
  label label: String,
) -> Element(Message) {
  let errors = form.field_error_messages(frm, name)

  html.div([attribute.class("flex flex-col gap-1 mb-4")], [
    html.label(
      [
        attribute.for(name),
        attribute.class(
          "text-2xs xs:text-xs sm:text-sm md:text-base uppercase tracking-wider text-muted italic",
        ),
      ],
      [html.text(label)],
    ),
    html.input([
      attribute.type_(type_),
      attribute.id(name),
      attribute.name(name),
      attribute.default_value(form.field_value(frm, name)),
      attribute.class(
        "bg-elevated border border-elevated rounded-lg px-2 py-1 xs:px-3 xs:py-2 sm:px-5 sm:py-3 md:px-6 md:py-4 text-fg text-xs xs:text-sm sm:text-base md:text-lg outline-none focus:border-accent",
      ),
    ]),
    ..list.map(errors, fn(message) {
      html.p([attribute.class("text-red-400 text-xs italic")], [
        html.text(message),
      ])
    })
  ])
}

fn view_add_icon() -> Element(msg) {
  svg.svg(
    [
      attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
      attribute.attribute("fill", "currentColor"),
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.class(
        "size-4 xs:size-5 sm:size-6 md:size-7 lg:size-8 xl:size-9",
      ),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M8 4a.5.5 0 0 1 .5.5v3h3a.5.5 0 0 1 0 1h-3v3a.5.5 0 0 1-1 0v-3h-3a.5.5 0 0 1 0-1h3v-3A.5.5 0 0 1 8 4",
        ),
      ]),
    ],
  )
}

fn record_type(record: records.Record) -> records.RecordType {
  case record {
    records.ARecord(..) -> records.A
    records.AaaaRecord(..) -> records.Aaaa
    records.CnameRecord(..) -> records.Cname
  }
}

fn view_record(
  deleting: option.Option(#(String, records.RecordType)),
  global_busy: Bool,
  record: records.Record,
) -> #(String, Element(Message)) {
  let type_label = case record {
    records.ARecord(..) -> "A"
    records.AaaaRecord(..) -> "AAAA"
    records.CnameRecord(..) -> "CNAME"
  }

  let value = case record {
    records.ARecord(ip:, ..) -> ip.ipv4_to_string(ip)
    records.AaaaRecord(ip:, ..) -> ip.ipv6_to_string(ip)
    records.CnameRecord(target:, ..) -> target
  }

  let ttl_label = int.to_string(record.ttl) <> "s"
  let key = record.name <> "/" <> type_label
  let this_key = #(record.name, record_type(record))

  let dimmed = case deleting {
    option.Some(pending) if pending == this_key -> False
    option.Some(_) -> True
    option.None -> global_busy
  }

  let row_class =
    "border-b border-elevated transition-opacity duration-200"
    <> case dimmed {
      True -> " opacity-25 pointer-events-none"
      False -> ""
    }

  let delete_button = case deleting {
    option.Some(pending) if pending == this_key ->
      html.button(
        [
          event.on_click(UserConfirmedDelete(this_key)),
          attribute.class(
            "text-red-400 hover:text-red-300 text-2xs xs:text-sm sm:text-base md:text-lg transition-colors cursor-pointer italic",
          ),
        ],
        [html.text("Sure?")],
      )
    _ ->
      html.button(
        [
          event.on_click(UserClickedDelete(this_key)),
          attribute.class(
            "text-subtle hover:text-red-400 text-2xs xs:text-sm sm:text-base md:text-lg transition-colors cursor-pointer",
          ),
        ],
        [html.text("Delete")],
      )
  }

  html.tr([attribute.class(row_class)], [
    html.td(
      [
        attribute.class(
          "py-1 xs:py-3 sm:py-4 md:py-5 text-2xs xs:text-sm sm:text-base md:text-lg text-fg",
        ),
      ],
      [html.text(record.name)],
    ),
    html.td(
      [
        attribute.class(
          "py-1 xs:py-3 sm:py-4 md:py-5 text-2xs xs:text-sm sm:text-base md:text-lg text-subtle font-mono",
        ),
      ],
      [html.text(type_label)],
    ),
    html.td(
      [
        attribute.class(
          "py-1 xs:py-3 sm:py-4 md:py-5 text-2xs xs:text-sm sm:text-base md:text-lg text-muted",
        ),
      ],
      [html.text(value)],
    ),
    html.td(
      [
        attribute.class(
          "py-1 xs:py-3 sm:py-4 md:py-5 text-2xs xs:text-sm sm:text-base md:text-lg text-subtle",
        ),
      ],
      [html.text(ttl_label)],
    ),
    html.td([attribute.class("py-1 xs:py-3 sm:py-4 md:py-5 text-right")], [
      html.button(
        [
          event.on_click(UserClickedEdit(record)),
          attribute.class(
            "text-subtle hover:text-fg text-2xs xs:text-sm sm:text-base md:text-lg transition-colors cursor-pointer "
            <> case deleting {
              option.Some(pending) if pending == this_key ->
                "mr-[10px] xs:mr-[20.5px] sm:mr-[25.5px] md:mr-[31px]"
              _ -> "mr-1 xs:mr-3 sm:mr-4 md:mr-5"
            },
          ),
        ],
        [html.text("Edit")],
      ),
      delete_button,
    ]),
  ])
  |> pair.new(key, _)
}
