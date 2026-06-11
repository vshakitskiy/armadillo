import formal/form
import gleam/dynamic/decode
import gleam/http/response
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
    records: List(#(String, String)),
    loading: Bool,
    saving: Bool,
    error: option.Option(String),
    popup: Popup,
    deleting: option.Option(String),
  )
}

type Popup {
  Hidden
  Visible(PopupContent)
  Closing(PopupContent)
}

type PopupContent {
  InsertContent(form.Form(records.Record))
  UpdateContent(records.Record, form.Form(String))
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

fn new_insert_form() -> form.Form(records.Record) {
  form.new({
    use domain <- form.field(
      "domain",
      form.parse_string |> form.check_not_empty,
    )

    use ip <- form.field("ip", parse_ip())

    form.success(records.Record(domain:, ip:))
  })
}

fn new_update_form(ip: String) -> form.Form(String) {
  form.new({
    use ip <- form.field("ip", parse_ip())

    form.success(ip)
  })
  |> form.add_string("ip", ip)
}

fn parse_ip() {
  form.parse(fn(values) {
    case values {
      ["", ..] -> Error(#("", "must not be blank"))
      [ip, ..] ->
        case ip.from_string(ip) {
          Ok(..) -> Ok(ip)
          Error(..) -> Error(#("", "must be valid ip"))
        }
      _ -> Error(#("", "must not be blank"))
    }
  })
}

fn fetch_records(
  on_response handle_response: fn(
    Result(List(#(String, String)), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  decode.list(of: records.keyed_decoder())
  |> rsvp.expect_json(handle_response)
  |> rsvp.get("/api/records", _)
}

fn insert_records(
  record: records.Record,
  on_response handle_response: fn(
    records.Record,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(handle_response(record, _))
  |> rsvp.post("/api/records", records.to_json(record), _)
}

fn update_record(
  record: records.Record,
  on_response handle_response: fn(
    records.Record,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(handle_response(record, _))
  |> rsvp.patch("/api/records/" <> record.domain, json.string(record.ip), _)
}

fn delete_record(
  domain: String,
  on_response handle_response: fn(
    String,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(handle_response(domain, _))
  |> rsvp.delete("/api/records/" <> domain, json.null(), _)
}

type Message {
  ApiFetchReturned(Result(List(#(String, String)), rsvp.Error(String)))

  UserClosedPopup
  PopupAnimationEnded

  UserClickedInsert
  UserSubmittedInsertForm(Result(records.Record, form.Form(records.Record)))
  ApiInsertReturned(
    record: records.Record,
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserClickedEdit(current_record: records.Record)
  UserSubmittedUpdateForm(
    domain: String,
    form: Result(String, form.Form(String)),
  )
  ApiUpdateReturned(
    updated_record: records.Record,
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserClickedDelete(domain: String)
  UserConfirmedDelete(domain: String)
  DeleteCancelled(domain: String)
  ApiDeleteReturned(
    domain: String,
    result: Result(response.Response(String), rsvp.Error(String)),
  )
}

@external(javascript, "./timer_ffi.mjs", "set_timeout")
fn set_timeout(callback: fn() -> Nil, ms: Int) -> Nil

fn delete_cancel_after(domain: String, ms: Int) -> effect.Effect(Message) {
  use dispatch <- effect.from
  set_timeout(fn() { dispatch(DeleteCancelled(domain)) }, ms)
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

    Model(popup: Hidden, ..), UserClickedInsert -> #(
      Model(..model, popup: Visible(InsertContent(new_insert_form()))),
      effect.none(),
    )
    _model, UserClickedInsert -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(..)), ..),
      UserSubmittedInsertForm(Ok(record))
    -> #(
      Model(..model, saving: True),
      insert_records(record, ApiInsertReturned),
    )
    Model(popup: Visible(InsertContent(..)), ..),
      UserSubmittedInsertForm(Error(form))
    -> #(Model(..model, popup: Visible(InsertContent(form))), effect.none())
    _model, UserSubmittedInsertForm(_) -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(..)), ..),
      ApiInsertReturned(
        record: records.Record(domain:, ip:),
        result: Ok(_response),
      )
    -> {
      let records = list.key_set(model.records, domain, ip)
      #(Model(..model, records:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Visible(InsertContent(..)), ..),
      ApiInsertReturned(_record, result: Error(_))
    -> {
      let error = option.Some("Something went wrong inserting record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
    Model(..), ApiInsertReturned(..) -> panic as "unreachable!"

    Model(popup: Hidden, ..), UserClickedEdit(current_record) -> {
      let popup =
        Visible(UpdateContent(
          current_record,
          new_update_form(current_record.ip),
        ))
      #(Model(..model, popup:), effect.none())
    }
    _model, UserClickedEdit(..) -> panic as "unreachable!"

    Model(popup: Visible(UpdateContent(..)), ..),
      UserSubmittedUpdateForm(domain, form: Ok(ip))
    -> #(
      Model(..model, saving: True),
      update_record(records.Record(domain:, ip:), ApiUpdateReturned),
    )
    Model(popup: Visible(UpdateContent(record, ..)), ..),
      UserSubmittedUpdateForm(form: Error(form), ..)
    -> #(
      Model(..model, popup: Visible(UpdateContent(record, form))),
      effect.none(),
    )
    _model, UserSubmittedUpdateForm(..) -> panic as "unreachable!"

    Model(popup: Visible(UpdateContent(..)), ..),
      ApiUpdateReturned(record, result: Ok(_response))
    -> {
      let records = list.key_set(model.records, record.domain, record.ip)
      #(Model(..model, records:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Visible(UpdateContent(..)), ..),
      ApiUpdateReturned(_record, result: Error(_))
    -> {
      let error = option.Some("Something went wrong updating record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
    Model(..), ApiUpdateReturned(..) -> panic as "unreachable!"

    model, UserClickedDelete(domain) -> #(
      Model(..model, deleting: option.Some(domain)),
      delete_cancel_after(domain, 3000),
    )

    model, DeleteCancelled(domain) ->
      case model.deleting {
        option.Some(pending) if pending == domain -> #(
          Model(..model, deleting: option.None),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    model, UserConfirmedDelete(domain) -> #(
      Model(..model, saving: True, deleting: option.None),
      delete_record(domain, ApiDeleteReturned),
    )

    model, ApiDeleteReturned(domain:, result: Ok(_response)) -> {
      let records = case list.key_pop(model.records, domain) {
        Ok(#(_domain, records)) -> records
        Error(Nil) -> model.records
      }

      #(Model(..model, records:, saving: False), effect.none())
    }
    model, ApiDeleteReturned(_domain, result: Error(_)) -> {
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
    html.div([attribute.class("max-w-2xl mx-auto p-8")], [
      case model.error {
        option.Some(message) ->
          html.p(
            [attribute.class("text-red-400 text-sm mb-4 bg-red-950 p-2 italic")],
            [html.text(message)],
          )
        option.None -> element.none()
      },
      html.header([attribute.class("flex items-center mb-8")], [
        html.img([
          attribute.src("/armadillo.svg"),
          attribute.class("size-10 mr-2"),
        ]),
        html.h1(
          [attribute.class("text-2xl font-semibold tracking-tight mr-4")],
          [
            html.text("DNS Records"),
          ],
        ),
        html.button(
          [
            event.on_click(UserClickedInsert),
            attribute.class(
              "w-8 h-8 rounded-md bg-accent text-fg flex items-center justify-center hover:bg-accent/80 transition-colors cursor-pointer",
            ),
          ],
          [view_add_icon()],
        ),
      ]),
      case model.loading {
        True ->
          html.p([attribute.class("text-subtle text-sm italic")], [
            html.text("Loading..."),
          ])
        False ->
          html.table([attribute.class("w-full border-collapse")], [
            html.thead([], [
              html.tr([], [
                html.th(
                  [
                    attribute.class(
                      "text-left text-xs uppercase tracking-wider text-subtle pb-3 border-b border-elevated font-medium italic",
                    ),
                  ],
                  [html.text("domain")],
                ),
                html.th(
                  [
                    attribute.class(
                      "text-left text-xs uppercase tracking-wider text-subtle pb-3 border-b border-elevated font-medium italic",
                    ),
                  ],
                  [html.text("ip")],
                ),
                html.th([attribute.class("pb-3 border-b border-elevated")], []),
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
    ]),
  ])
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
            "bg-surface border border-elevated rounded-xl p-6 w-80 shadow-2xl "
            <> card_class,
          ),
          event.on("animationend", decode.success(PopupAnimationEnded)),
        ],
        [
          case content {
            InsertContent(form) -> view_insert(form, saving)
            UpdateContent(record, form) -> view_update(record, form, saving)
          },
        ],
      ),
    ],
  )
}

fn view_insert(
  form: form.Form(records.Record),
  saving: Bool,
) -> element.Element(Message) {
  let handle_submit = fn(values) {
    form.add_values(form, values) |> form.run |> UserSubmittedInsertForm
  }

  html.form([event.on_submit(handle_submit), attribute.class("flex flex-col")], [
    html.h2([attribute.class("text-base font-semibold mb-4")], [
      html.text("Add Record"),
    ]),
    view_input(form, is: "text", name: "domain", label: "Domain"),
    view_input(form, is: "text", name: "ip", label: "IP"),
    html.button(
      [
        attribute.disabled(saving),
        attribute.class(
          "mt-2 py-2 rounded-lg text-sm font-medium"
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

fn view_update(
  record: records.Record,
  form: form.Form(String),
  saving: Bool,
) -> Element(Message) {
  let handle_submit = fn(values) {
    form.add_values(form, values)
    |> form.run
    |> UserSubmittedUpdateForm(record.domain, _)
  }

  html.form([event.on_submit(handle_submit), attribute.class("flex flex-col")], [
    html.h2([attribute.class("text-base font-semibold mb-1")], [
      html.text("Edit Record"),
    ]),
    html.p([attribute.class("text-xs text-subtle mb-4 italic")], [
      html.text(record.domain),
    ]),
    view_input(form, is: "text", name: "ip", label: "IP"),
    html.button(
      [
        attribute.disabled(saving),
        attribute.class(
          "mt-2 py-2 rounded-lg text-sm font-medium"
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
  form: form.Form(data),
  is type_: String,
  name name: String,
  label label: String,
) -> Element(Message) {
  let errors = form.field_error_messages(form, name)

  html.div([attribute.class("flex flex-col gap-1 mb-4")], [
    html.label(
      [
        attribute.for(name),
        attribute.class("text-xs uppercase tracking-wider text-muted italic"),
      ],
      [html.text(label)],
    ),
    html.input([
      attribute.type_(type_),
      attribute.id(name),
      attribute.name(name),
      attribute.default_value(form.field_value(form, name)),
      attribute.class(
        "bg-elevated border border-elevated rounded-lg px-3 py-2 text-fg text-sm outline-none focus:border-accent",
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
      attribute.attribute("width", "16"),
      attribute.attribute("height", "16"),
      attribute.attribute("fill", "currentColor"),
      attribute.attribute("viewBox", "0 0 16 16"),
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

fn view_record(
  deleting: option.Option(String),
  global_busy: Bool,
  record: #(String, String),
) -> #(String, Element(Message)) {
  let #(domain, ip) = record

  let dimmed = case deleting {
    option.Some(d) if d == domain -> False
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
    option.Some(pending) if pending == domain ->
      html.button(
        [
          event.on_click(UserConfirmedDelete(domain)),
          attribute.class(
            "text-red-400 hover:text-red-300 text-xs transition-colors cursor-pointer italic",
          ),
        ],
        [html.text("Sure?")],
      )
    _ ->
      html.button(
        [
          event.on_click(UserClickedDelete(domain)),
          attribute.class(
            "text-subtle hover:text-red-400 text-xs transition-colors cursor-pointer",
          ),
        ],
        [html.text("Delete")],
      )
  }

  html.tr([attribute.class(row_class)], [
    html.td([attribute.class("py-3 text-sm text-fg")], [
      html.text(domain),
    ]),
    html.td([attribute.class("py-3 text-sm text-muted")], [
      html.text(ip),
    ]),
    html.td([attribute.class("py-3 text-right")], [
      html.button(
        [
          event.on_click(UserClickedEdit(records.Record(domain:, ip:))),
          attribute.class(
            "text-subtle hover:text-fg text-xs transition-colors cursor-pointer "
            <> case deleting {
              option.Some(pending) if pending == domain -> "mr-[19.5px]"
              _ -> "mr-3"
            },
          ),
        ],
        [html.text("Edit")],
      ),
      delete_button,
    ]),
  ])
  |> pair.new(domain, _)
}
