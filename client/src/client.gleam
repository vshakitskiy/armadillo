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
  )
}

type Popup {
  Hidden
  Insert(form.Form(records.Record))
  Update(records.Record, form.Form(String))
}

fn init(_args: Nil) -> #(Model, effect.Effect(Message)) {
  Model(
    records: [],
    loading: True,
    saving: False,
    error: option.None,
    popup: Hidden,
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

fn new_update_form() -> form.Form(String) {
  form.new({
    use ip <- form.field("ip", parse_ip())

    form.success(ip)
  })
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
  ApiDeleteReturned(
    domain: String,
    result: Result(response.Response(String), rsvp.Error(String)),
  )
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
    Model(saving: True, ..), UserClosedPopup -> #(model, effect.none())
    Model(saving: False, ..), UserClosedPopup -> {
      #(Model(..model, popup: Hidden), effect.none())
    }

    Model(popup: Hidden, ..), UserClickedInsert -> {
      #(Model(..model, popup: Insert(new_insert_form())), effect.none())
    }
    _model, UserClickedInsert -> panic as "unreachable!"

    Model(popup: Insert(..), ..), UserSubmittedInsertForm(Ok(record)) -> #(
      Model(..model, saving: True),
      insert_records(record, ApiInsertReturned),
    )
    Model(popup: Insert(..), ..), UserSubmittedInsertForm(Error(form)) -> #(
      Model(..model, popup: Insert(form)),
      effect.none(),
    )
    _model, UserSubmittedInsertForm(_) -> panic as "unreachable!"

    Model(popup: Insert(..), ..),
      ApiInsertReturned(
        record: records.Record(domain:, ip:),
        result: Ok(_response),
      )
    -> {
      let records = list.key_set(model.records, domain, ip)
      #(Model(..model, records:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Insert(..), ..), ApiInsertReturned(_record, result: Error(_))
    -> {
      let error = option.Some("Something went wrong inserting record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
    Model(..), ApiInsertReturned(..) -> panic as "unreachable!"

    Model(popup: Hidden, ..), UserClickedEdit(current_record) -> {
      #(
        Model(..model, popup: Update(current_record, new_update_form())),
        effect.none(),
      )
    }
    _model, UserClickedEdit(..) -> panic as "unreachable!"

    Model(popup: Update(..), ..), UserSubmittedUpdateForm(domain, form: Ok(ip))
    -> #(
      Model(..model, saving: True),
      update_record(records.Record(domain:, ip:), ApiUpdateReturned),
    )
    Model(popup: Update(record, ..), ..),
      UserSubmittedUpdateForm(form: Error(form), ..)
    -> #(Model(..model, popup: Update(record, form)), effect.none())
    _model, UserSubmittedUpdateForm(..) -> panic as "unreachable!"

    Model(popup: Update(..), ..),
      ApiUpdateReturned(record, result: Ok(_response))
    -> {
      let records = list.key_set(model.records, record.domain, record.ip)
      #(Model(..model, records:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Update(..), ..), ApiUpdateReturned(_record, result: Error(_))
    -> {
      let error = option.Some("Something went wrong updating record!")
      #(Model(..model, saving: False, error:), effect.none())
    }
    Model(..), ApiUpdateReturned(..) -> panic as "unreachable!"

    model, UserClickedDelete(domain) -> #(
      Model(..model, saving: True),
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
  element.fragment([
    case model.popup {
      Hidden -> element.none()
      Insert(form) -> view_popup(form, view_insert)
      Update(record, form) -> view_popup(form, view_update(record, _))
    },
    case model.error {
      option.Some(message) -> html.p([], [html.text(message)])
      option.None -> element.none()
    },
    html.div([], [
      html.h1([], [html.text("Records")]),
      html.button([event.on_click(UserClickedInsert)], [html.text("+")]),
    ]),
    case model.loading {
      True -> html.p([], [html.text("Loading ...")])
      False ->
        element.fragment([
          html.table([], [
            html.thead([], [
              html.tr([], [
                html.th([], [html.text("Domain")]),
                html.th([], [html.text("IP")]),
              ]),
            ]),
            keyed.tbody([], list.map(model.records, view_record)),
          ]),
        ])
    },
  ])
}

fn view_popup(
  form: form.Form(data),
  view_form: fn(form.Form(data)) -> Element(Message),
) -> element.Element(Message) {
  html.div(
    [
      attribute.class(
        "fixed bg-black/45 z-1 size-full flex items-center justify-center",
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
      html.div([attribute.class("bg-white p-4")], [view_form(form)]),
    ],
  )
}

fn view_insert(form: form.Form(records.Record)) -> element.Element(Message) {
  let handle_submit = fn(values) {
    form.add_values(form, values) |> form.run |> UserSubmittedInsertForm
  }

  html.form([event.on_submit(handle_submit)], [
    view_input(form, is: "text", name: "domain", label: "Domain"),
    view_input(form, is: "text", name: "ip", label: "IP"),
    html.button([], [html.text("Add")]),
  ])
}

fn view_update(
  record: records.Record,
  form: form.Form(String),
) -> Element(Message) {
  let handle_submit = fn(values) {
    form.add_values(form, values)
    |> form.run
    |> UserSubmittedUpdateForm(record.domain, _)
  }

  html.form([event.on_submit(handle_submit)], [
    view_input(form, is: "text", name: "ip", label: "IP"),
    html.button([], [html.text("Update")]),
  ])
}

fn view_input(
  form: form.Form(data),
  is type_: String,
  name name: String,
  label label: String,
) -> Element(Message) {
  let errors = form.field_error_messages(form, name)

  html.div([], [
    html.label([attribute.for(name)], [html.text(label), html.text(": ")]),
    html.input([
      attribute.type_(type_),
      attribute.id(name),
      attribute.name(name),
      attribute.default_value(form.field_value(form, name)),
    ]),
    ..list.map(errors, fn(message) { html.p([], [html.text(message)]) })
  ])
}

fn view_record(record: #(String, String)) -> #(String, Element(Message)) {
  let #(domain, ip) = record

  html.tr([], [
    html.td([], [html.text(domain)]),
    html.td([], [html.text(ip)]),
    html.td([], [
      html.button(
        [event.on_click(UserClickedEdit(records.Record(domain:, ip:)))],
        [html.text("Edit")],
      ),
      html.button([event.on_click(UserClickedDelete(domain))], [
        html.text("Delete"),
      ]),
    ]),
  ])
  |> pair.new(domain, _)
}
