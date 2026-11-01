import armadillo/shared/ip
import armadillo/shared/record
import gleam/bool
import gleam/dynamic/decode
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import rsvp

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let assert Ok(_app) = lustre.start(app, "#app", Nil)
  Nil
}

type EntryDraft {
  EntryDraft(
    type_: record.RecordType,
    value: String,
    ttl: String,
    value_error: Option(String),
    ttl_error: Option(String),
  )
}

fn default_entries() -> List(EntryDraft) {
  [
    EntryDraft(
      type_: record.A,
      value: "",
      ttl: "300",
      value_error: None,
      ttl_error: None,
    ),
  ]
}

type Model {
  Model(
    domains: List(record.DomainGroup),
    loading: Bool,
    pending_request: PendingRequest,
    error: Option(String),
    popup: Popup,
    confirming_delete: Option(String),
  )
}

type PendingRequest {
  NoRequest
  Inserting(domain: String)
  Updating(domain: String)
  Deleting(domain: String)
}

type Popup {
  Hidden
  Visible(PopupContent)
  Closing(PopupContent)
}

type PopupContent {
  InsertContent(
    domain: String,
    domain_error: Option(String),
    entries: List(EntryDraft),
    form_error: Option(String),
  )
  EditContent(
    domain: String,
    entries: List(EntryDraft),
    form_error: Option(String),
  )
}

fn init(_args: Nil) -> #(Model, effect.Effect(Message)) {
  let model =
    Model(
      domains: [],
      loading: True,
      pending_request: NoRequest,
      error: None,
      popup: Hidden,
      confirming_delete: None,
    )
  let fetch_domains = api_fetch_domains(ApiFetchReturned)

  #(model, fetch_domains)
}

fn api_fetch_domains(
  on_response: fn(Result(List(record.DomainGroup), rsvp.Error(String))) ->
    Message,
) -> effect.Effect(Message) {
  decode.list(of: record.domain_group_decoder())
  |> rsvp.expect_json(on_response)
  |> rsvp.get("/api/domains", _)
}

fn api_insert_domain(
  group: record.DomainGroup,
  on_response: fn(
    record.DomainGroup,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(on_response(group, _))
  |> rsvp.post("/api/domains", record.domain_group_to_json(group), _)
}

fn api_put_domain(
  name: String,
  entries: List(record.RecordEntry),
  on_response: fn(
    String,
    List(record.RecordEntry),
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(on_response(name, entries, _))
  |> rsvp.put(domain_url(name), json.array(entries, record.entry_to_json), _)
}

fn api_delete_domain(
  name: String,
  on_response: fn(String, Result(response.Response(String), rsvp.Error(String))) ->
    Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(on_response(name, _))
  |> rsvp.delete(domain_url(name), json.object([]), _)
}

fn domain_url(name: String) -> String {
  "/api/domains?" <> uri.query_to_string([#("name", name)])
}

type Message {
  ApiFetchReturned(Result(List(record.DomainGroup), rsvp.Error(String)))

  UserClosedPopup
  PopupAnimationEnded

  UserClickedInsert
  UserChangedInsertDomain(String)
  UserSubmittedInsert
  ApiInsertReturned(
    group: record.DomainGroup,
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserClickedEdit(String)
  UserSubmittedEdit
  ApiPutReturned(
    domain: String,
    entries: List(record.RecordEntry),
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserChangedEntryType(Int, record.RecordType)
  UserChangedEntryValue(Int, String)
  UserChangedEntryTtl(Int, String)
  UserAddedEntry
  UserRemovedEntry(Int)

  UserClickedDelete(String)
  UserClickedDeleteDomainFromEdit(String)
  UserConfirmedDelete(String)
  DeleteCancelled(String)
  ApiDeleteReturned(
    domain: String,
    result: Result(response.Response(String), rsvp.Error(String)),
  )
}

@external(javascript, "./timer_ffi.mjs", "set_timeout")
fn set_timeout(ms: Int, callback: fn() -> Nil) -> Nil

fn delete_cancel_after(domain: String, ms: Int) -> effect.Effect(Message) {
  use dispatch <- effect.from
  use <- set_timeout(ms)
  dispatch(DeleteCancelled(domain))
}

fn update_entry_at(
  entries: List(EntryDraft),
  index: Int,
  callback: fn(EntryDraft) -> EntryDraft,
) -> List(EntryDraft) {
  use entry, entry_index <- list.index_map(entries)

  case entry_index == index {
    True -> callback(entry)
    False -> entry
  }
}

type EntryValue {
  Ipv4Value(ip.Ipv4)
  Ipv6Value(ip.Ipv6)
  CnameValue(String)
}

fn parse_entry_value(draft: EntryDraft) -> Result(EntryValue, String) {
  case draft.type_ {
    record.A ->
      ip.ipv4_from_string(draft.value)
      |> result.map(Ipv4Value)
      |> result.replace_error("must be a valid IPv4 address")
    record.Aaaa ->
      ip.ipv6_from_string(draft.value)
      |> result.map(Ipv6Value)
      |> result.replace_error("must be a valid IPv6 address")
    record.Cname -> {
      use _valid <- result.try(
        record.validate_name(draft.value)
        |> result.map_error(record.describe_name_error),
      )

      Ok(CnameValue(record.normalize_name(draft.value)))
    }
  }
}

fn parse_entry_ttl(text: String) -> Result(Int, String) {
  case int.parse(text) {
    Ok(ttl) if ttl > 0 && ttl <= 86_400 -> Ok(ttl)
    Ok(ttl) if ttl > 86_400 -> Error("must be ≤ 86400 (1 day)")
    Ok(_ttl) -> Error("must be a positive number")
    Error(Nil) -> Error("must be a number")
  }
}

fn validate_entry(draft: EntryDraft) -> Result(record.RecordEntry, EntryDraft) {
  let value_result = parse_entry_value(draft)
  let ttl_result = parse_entry_ttl(draft.ttl)

  case value_result, ttl_result {
    Ok(Ipv4Value(ip)), Ok(ttl) -> Ok(record.AEntry(ttl:, ip:))
    Ok(Ipv6Value(ip)), Ok(ttl) -> Ok(record.AaaaEntry(ttl:, ip:))
    Ok(CnameValue(target)), Ok(ttl) -> Ok(record.CnameEntry(ttl:, target:))
    _value_result, _ttl_result ->
      Error(
        EntryDraft(
          ..draft,
          value_error: case value_result {
            Error(message) -> Some(message)
            Ok(_value) -> None
          },
          ttl_error: case ttl_result {
            Error(message) -> Some(message)
            Ok(_ttl) -> None
          },
        ),
      )
  }
}

fn validate_entries(
  drafts: List(EntryDraft),
) -> Result(List(record.RecordEntry), List(EntryDraft)) {
  let #(validated, annotated_drafts) =
    list.map_fold(drafts, Ok([]), fn(validated, draft) {
      case validate_entry(draft) {
        Ok(entry) -> #(
          result.map(validated, fn(entries) { [entry, ..entries] }),
          draft,
        )
        Error(invalid_draft) -> #(Error(Nil), invalid_draft)
      }
    })

  case validated {
    Ok(entries) -> Ok(list.reverse(entries))
    Error(Nil) -> Error(annotated_drafts)
  }
}

fn update_popup_entries(
  model: Model,
  update_entries: fn(List(EntryDraft)) -> List(EntryDraft),
) -> #(Model, effect.Effect(Message)) {
  use <- bool.guard(when: model.pending_request != NoRequest, return: #(
    model,
    effect.none(),
  ))

  let popup = case model.popup {
    Visible(InsertContent(entries:, ..) as content) ->
      Visible(InsertContent(..content, entries: update_entries(entries)))
    Visible(EditContent(entries:, ..) as content) ->
      Visible(EditContent(..content, entries: update_entries(entries)))
    Hidden | Closing(..) -> model.popup
  }

  #(Model(..model, popup:), effect.none())
}

fn entry_to_draft(entry: record.RecordEntry) -> EntryDraft {
  let #(type_, value) = case entry {
    record.AEntry(ip:, ..) -> #(record.A, ip.ipv4_to_string(ip))
    record.AaaaEntry(ip:, ..) -> #(record.Aaaa, ip.ipv6_to_string(ip))
    record.CnameEntry(target:, ..) -> #(record.Cname, target)
  }

  EntryDraft(
    type_:,
    value:,
    ttl: int.to_string(entry.ttl),
    value_error: None,
    ttl_error: None,
  )
}

fn api_error(error: rsvp.Error(String)) -> String {
  case error {
    rsvp.HttpError(response) ->
      case string.is_empty(string.trim(response.body)) {
        False -> response.body
        True -> "Internal server error"
      }
    rsvp.NetworkError -> "Check your connection"
    rsvp.BadBody
    | rsvp.BadUrl(_url)
    | rsvp.JsonError(_decode_error)
    | rsvp.UnhandledResponse(_response) -> "Something went wrong"
  }
}

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case model, message {
    Model(loading: True, ..), ApiFetchReturned(Ok(domains)) -> #(
      Model(..model, domains:, loading: False),
      effect.none(),
    )
    Model(loading: True, ..), ApiFetchReturned(Error(error)) -> {
      let error = api_error(error)

      #(Model(..model, loading: False, error: Some(error)), effect.none())
    }
    _model, ApiFetchReturned(_late_response) -> #(model, effect.none())

    Model(popup: Visible(content), pending_request: NoRequest, ..),
      UserClosedPopup
    -> #(Model(..model, popup: Closing(content)), effect.none())
    _model, UserClosedPopup -> #(model, effect.none())

    Model(popup: Closing(..), ..), PopupAnimationEnded -> #(
      Model(..model, popup: Hidden),
      effect.none(),
    )
    _model, PopupAnimationEnded -> #(model, effect.none())

    Model(popup: Hidden, pending_request: NoRequest, loading: False, ..),
      UserClickedInsert
    -> {
      let content =
        InsertContent(
          domain: "",
          domain_error: None,
          entries: default_entries(),
          form_error: None,
        )

      #(
        Model(..model, popup: Visible(content), confirming_delete: None),
        effect.none(),
      )
    }
    _model, UserClickedInsert -> #(model, effect.none())

    Model(
      popup: Visible(InsertContent(..) as content),
      pending_request: NoRequest,
      ..,
    ),
      UserChangedInsertDomain(domain)
    -> {
      let content =
        InsertContent(..content, domain:, domain_error: None, form_error: None)

      #(Model(..model, popup: Visible(content)), effect.none())
    }
    _model, UserChangedInsertDomain(_domain) -> #(model, effect.none())

    model, UserChangedEntryType(index, type_) -> {
      use entries <- update_popup_entries(model)
      use draft <- update_entry_at(entries, index)

      EntryDraft(..draft, type_:, value_error: None)
    }
    model, UserChangedEntryValue(index, value) -> {
      use entries <- update_popup_entries(model)
      use draft <- update_entry_at(entries, index)

      EntryDraft(..draft, value:, value_error: None)
    }
    model, UserChangedEntryTtl(index, ttl) -> {
      use entries <- update_popup_entries(model)
      use draft <- update_entry_at(entries, index)

      EntryDraft(..draft, ttl:, ttl_error: None)
    }
    model, UserAddedEntry -> {
      use entries <- update_popup_entries(model)

      list.append(entries, default_entries())
    }
    model, UserRemovedEntry(index) -> {
      use entries <- update_popup_entries(model)

      list.append(list.take(entries, index), list.drop(entries, index + 1))
    }

    Model(
      popup: Visible(InsertContent(domain:, entries:, ..) as content),
      pending_request: NoRequest,
      ..,
    ),
      UserSubmittedInsert
    -> {
      let domain = string.trim(domain)
      let domain_error = case record.validate_name(domain) {
        Ok(Nil) -> None
        Error(reason) -> Some(record.describe_name_error(reason))
      }
      let entries_result = validate_entries(entries)

      case domain_error, entries_result {
        None, Ok(valid_entries) -> {
          let content = InsertContent(..content, form_error: None)
          let group =
            record.DomainGroup(
              name: record.normalize_name(domain),
              records: valid_entries,
            )
          let insert_domain = api_insert_domain(group, ApiInsertReturned)

          #(
            Model(
              ..model,
              pending_request: Inserting(group.name),
              popup: Visible(content),
            ),
            insert_domain,
          )
        }
        _domain_error, _entries_result -> {
          let entries = result.unwrap_error(entries_result, entries)
          let content =
            InsertContent(domain:, domain_error:, entries:, form_error: None)

          #(Model(..model, popup: Visible(content)), effect.none())
        }
      }
    }
    _model, UserSubmittedInsert -> #(model, effect.none())

    Model(
      pending_request: Inserting(expected),
      popup: Visible(InsertContent(..)),
      ..,
    ),
      ApiInsertReturned(group:, result: Ok(_response))
      if group.name == expected
    -> {
      let domains = list.append(model.domains, [group])

      #(
        Model(..model, domains:, pending_request: NoRequest, popup: Hidden),
        effect.none(),
      )
    }
    Model(
      pending_request: Inserting(expected),
      popup: Visible(InsertContent(..) as content),
      ..,
    ),
      ApiInsertReturned(group:, result: Error(error))
      if group.name == expected
    -> {
      let error = api_error(error)
      let popup = Visible(InsertContent(..content, form_error: Some(error)))

      #(Model(..model, pending_request: NoRequest, popup:), effect.none())
    }
    _model, ApiInsertReturned(..) -> #(model, effect.none())

    Model(popup: Hidden, pending_request: NoRequest, loading: False, ..),
      UserClickedEdit(domain)
    -> {
      case list.find(model.domains, fn(group) { group.name == domain }) {
        Ok(group) -> {
          let entries = list.map(group.records, entry_to_draft)
          let content = EditContent(domain:, entries:, form_error: None)

          #(
            Model(..model, popup: Visible(content), confirming_delete: None),
            effect.none(),
          )
        }
        Error(Nil) -> #(model, effect.none())
      }
    }
    _model, UserClickedEdit(_domain) -> #(model, effect.none())

    Model(
      popup: Visible(EditContent(domain:, entries:, ..) as content),
      pending_request: NoRequest,
      ..,
    ),
      UserSubmittedEdit
    -> {
      case validate_entries(entries) {
        Ok(valid_entries) -> {
          let content = EditContent(..content, form_error: None)
          let update_domain =
            api_put_domain(domain, valid_entries, ApiPutReturned)

          #(
            Model(
              ..model,
              pending_request: Updating(domain),
              popup: Visible(content),
            ),
            update_domain,
          )
        }
        Error(updated_entries) -> {
          let content =
            EditContent(..content, entries: updated_entries, form_error: None)

          #(Model(..model, popup: Visible(content)), effect.none())
        }
      }
    }
    _model, UserSubmittedEdit -> #(model, effect.none())

    Model(
      pending_request: Updating(expected),
      popup: Visible(EditContent(..)),
      ..,
    ),
      ApiPutReturned(domain:, entries:, result: Ok(_response))
      if domain == expected
    -> {
      let domains =
        list.map(model.domains, fn(group) {
          case group.name == domain {
            True -> record.DomainGroup(name: domain, records: entries)
            False -> group
          }
        })

      #(
        Model(..model, domains:, pending_request: NoRequest, popup: Hidden),
        effect.none(),
      )
    }
    Model(
      pending_request: Updating(expected),
      popup: Visible(EditContent(..) as content),
      ..,
    ),
      ApiPutReturned(domain:, entries: _entries, result: Error(error))
      if domain == expected
    -> {
      let error = api_error(error)
      let popup = Visible(EditContent(..content, form_error: Some(error)))

      #(Model(..model, pending_request: NoRequest, popup:), effect.none())
    }
    _model, ApiPutReturned(..) -> #(model, effect.none())

    Model(popup: Hidden, pending_request: NoRequest, loading: False, ..),
      UserClickedDelete(domain)
    -> #(
      Model(..model, confirming_delete: Some(domain)),
      delete_cancel_after(domain, 3000),
    )
    _model, UserClickedDelete(_domain) -> #(model, effect.none())

    Model(
      popup: Visible(EditContent(domain:, ..) as content),
      pending_request: NoRequest,
      ..,
    ),
      UserClickedDeleteDomainFromEdit(expected)
      if domain == expected
    -> #(
      Model(..model, popup: Closing(content), confirming_delete: Some(domain)),
      delete_cancel_after(domain, 3000),
    )
    _model, UserClickedDeleteDomainFromEdit(_domain) -> #(model, effect.none())

    Model(confirming_delete: Some(pending), ..), DeleteCancelled(domain)
      if pending == domain
    -> #(Model(..model, confirming_delete: None), effect.none())
    _model, DeleteCancelled(_domain) -> #(model, effect.none())

    Model(
      popup: Hidden,
      pending_request: NoRequest,
      loading: False,
      confirming_delete: Some(expected),
      ..,
    ),
      UserConfirmedDelete(domain)
      if domain == expected
    -> {
      let delete_domain = api_delete_domain(domain, ApiDeleteReturned)

      #(
        Model(
          ..model,
          pending_request: Deleting(domain),
          confirming_delete: None,
        ),
        delete_domain,
      )
    }
    _model, UserConfirmedDelete(_domain) -> #(model, effect.none())

    Model(pending_request: Deleting(expected), ..),
      ApiDeleteReturned(domain:, result: Ok(_response))
      if domain == expected
    -> {
      let domains =
        list.filter(model.domains, fn(group) { group.name != domain })

      #(Model(..model, domains:, pending_request: NoRequest), effect.none())
    }
    Model(pending_request: Deleting(expected), ..),
      ApiDeleteReturned(domain:, result: Error(error))
      if domain == expected
    -> {
      let error = Some(api_error(error))

      #(Model(..model, pending_request: NoRequest, error:), effect.none())
    }
    _model, ApiDeleteReturned(..) -> #(model, effect.none())
  }
}

fn view_field_error(error: Option(String)) -> Element(msg) {
  case error {
    Some(message) ->
      html.p([attribute.class("text-red-400 text-2xs xs:text-xs italic")], [
        html.text(message),
      ])
    None -> element.none()
  }
}

fn input_border_state(error: Option(String)) -> String {
  case error {
    Some(_error) -> "border-red-500"
    None -> "border-elevated focus:border-accent"
  }
}

fn view_entries_list(entries: List(EntryDraft)) -> Element(Message) {
  let can_remove = list.length(entries) > 1

  html.div([attribute.class("flex-1 min-h-0 overflow-y-auto")], [
    html.div(
      [],
      list.index_map(entries, fn(entry, index) {
        view_entry_draft(index, entry, can_remove)
      }),
    ),
    html.button(
      [
        attribute.type_("button"),
        event.on_click(UserAddedEntry),
        attribute.class(
          "text-subtle hover:text-fg text-2xs xs:text-xs sm:text-sm transition-colors cursor-pointer mb-3 xs:mb-4 sm:mb-6 text-left",
        ),
      ],
      [html.text("+ Add record")],
    ),
  ])
}

fn view(model: Model) -> Element(Message) {
  let saving = model.pending_request != NoRequest
  let global_busy = model.loading || saving || model.popup != Hidden

  html.div([attribute.class("min-h-screen bg-bg text-fg")], [
    case model.popup {
      Hidden -> element.none()
      Visible(content) -> view_popup(content, False, saving)
      Closing(content) -> view_popup(content, True, saving)
    },
    html.div(
      [
        attribute.class(
          "w-full max-w-sm xs:max-w-lg sm:max-w-2xl md:max-w-3xl lg:max-w-5xl xl:max-w-6xl mx-auto px-2 py-3 xs:px-5 xs:py-6 sm:px-9 sm:py-9 md:px-12 md:py-12 lg:px-16 lg:py-14",
        ),
      ],
      [
        case model.error {
          Some(message) ->
            html.p(
              [
                attribute.class(
                  "text-red-400 text-xs sm:text-base md:text-lg mb-3 sm:mb-5 bg-red-950 p-2 italic",
                ),
              ],
              [html.text(message)],
            )
          None -> element.none()
        },
        view_header(global_busy),
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
            html.div(
              [
                attribute.class(
                  "flex flex-col gap-2 xs:gap-3 sm:gap-4 md:gap-5",
                ),
              ],
              list.map(model.domains, view_domain_card(
                _,
                model.confirming_delete,
                global_busy,
              )),
            )
        },
      ],
    ),
  ])
}

fn view_header(busy: Bool) -> Element(Message) {
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
          attribute.disabled(busy),
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

fn view_popup(
  content: PopupContent,
  closing: Bool,
  saving: Bool,
) -> Element(Message) {
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
          _other_id -> decode.failure(UserClosedPopup, "")
        }
      }),
    ],
    [
      html.div(
        [
          attribute.class(
            "bg-surface border border-elevated rounded-xl p-3 xs:p-5 sm:p-8 md:p-10 lg:p-12 w-[calc(100vw-3rem)] max-w-xs xs:max-w-sm sm:max-w-md md:max-w-lg lg:max-w-xl xl:max-w-2xl shadow-2xl max-h-[calc(100dvh-2rem)] flex flex-col overflow-hidden "
            <> card_class,
          ),
          event.on("animationend", decode.success(PopupAnimationEnded)),
        ],
        [
          case content {
            InsertContent(domain:, domain_error:, entries:, form_error:) ->
              view_insert_popup(
                domain,
                domain_error,
                entries,
                saving,
                form_error,
              )
            EditContent(domain:, entries:, form_error:) ->
              view_edit_popup(domain, entries, saving, form_error)
          },
        ],
      ),
    ],
  )
}

fn view_insert_popup(
  domain: String,
  domain_error: Option(String),
  entries: List(EntryDraft),
  saving: Bool,
  form_error: Option(String),
) -> Element(Message) {
  html.div([attribute.class("flex flex-col flex-1 min-h-0")], [
    html.h2(
      [
        attribute.class(
          "text-xs xs:text-base sm:text-xl md:text-2xl font-semibold mb-2 xs:mb-4 sm:mb-6 md:mb-8 shrink-0",
        ),
      ],
      [html.text("Add Domain")],
    ),
    html.div([attribute.class("flex flex-col gap-1 mb-4 shrink-0")], [
      html.label(
        [
          attribute.for("domain"),
          attribute.class(
            "text-2xs xs:text-xs sm:text-sm md:text-base uppercase tracking-wider text-muted italic",
          ),
        ],
        [html.text("Domain")],
      ),
      html.input([
        attribute.type_("text"),
        attribute.id("domain"),
        attribute.value(domain),
        attribute.placeholder("domain.lan"),
        event.on_input(UserChangedInsertDomain),
        attribute.class(
          "bg-elevated border "
          <> input_border_state(domain_error)
          <> " rounded-lg px-2 py-1 xs:px-3 xs:py-2 sm:px-5 sm:py-3 text-fg text-xs xs:text-sm sm:text-base outline-none",
        ),
      ]),
      view_field_error(domain_error),
    ]),
    view_entries_list(entries),
    case form_error {
      Some(error) ->
        html.p(
          [
            attribute.class(
              "mt-2 shrink-0 text-red-400 text-2xs xs:text-xs sm:text-sm italic",
            ),
          ],
          [html.text(error)],
        )
      None -> element.none()
    },
    html.button(
      [
        attribute.disabled(saving),
        event.on_click(UserSubmittedInsert),
        attribute.class(
          "mt-2 xs:mt-3 shrink-0 py-1.5 xs:py-3 sm:py-4 md:py-5 rounded-lg text-xs xs:text-sm sm:text-base md:text-lg font-medium w-full "
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

fn view_edit_popup(
  domain: String,
  entries: List(EntryDraft),
  saving: Bool,
  form_error: Option(String),
) -> Element(Message) {
  html.div([attribute.class("flex flex-col flex-1 min-h-0")], [
    html.h2(
      [
        attribute.class(
          "text-xs xs:text-base sm:text-xl md:text-2xl font-semibold mb-1 shrink-0",
        ),
      ],
      [html.text("Edit Domain")],
    ),
    html.p(
      [
        attribute.class(
          "text-xs xs:text-sm text-subtle mb-3 xs:mb-4 sm:mb-6 italic break-all shrink-0",
        ),
      ],
      [html.text(domain)],
    ),
    view_entries_list(entries),
    case form_error {
      Some(error) ->
        html.p(
          [
            attribute.class(
              "mt-2 shrink-0 text-red-400 text-2xs xs:text-xs sm:text-sm italic",
            ),
          ],
          [html.text(error)],
        )
      None -> element.none()
    },
    html.div(
      [attribute.class("flex justify-between items-center mt-2 shrink-0")],
      [
        html.button(
          [
            attribute.type_("button"),
            attribute.disabled(saving),
            event.on_click(UserClickedDeleteDomainFromEdit(domain)),
            attribute.class(
              "text-red-400 hover:text-red-300 text-2xs xs:text-xs sm:text-sm transition-colors cursor-pointer",
            ),
          ],
          [html.text("Delete Domain")],
        ),
        html.button(
          [
            attribute.disabled(saving),
            event.on_click(UserSubmittedEdit),
            attribute.class(
              "py-1.5 xs:py-2 sm:py-3 px-4 xs:px-5 sm:px-7 rounded-lg text-xs xs:text-sm sm:text-base font-medium "
              <> case saving {
                True -> "bg-accent/50 text-fg/50 cursor-not-allowed"
                False ->
                  "bg-accent text-fg hover:bg-accent/80 transition-colors cursor-pointer"
              },
            ),
          ],
          [html.text("Save")],
        ),
      ],
    ),
  ])
}

fn view_entry_draft(
  index: Int,
  draft: EntryDraft,
  can_remove: Bool,
) -> Element(Message) {
  let value_input_class =
    "bg-elevated border "
    <> input_border_state(draft.value_error)
    <> " rounded-lg px-2 py-1 xs:px-3 xs:py-2 text-fg text-xs xs:text-sm outline-none w-full"

  let ttl_input_class =
    "bg-elevated border "
    <> input_border_state(draft.ttl_error)
    <> " rounded-lg px-2 py-1 xs:px-2 xs:py-2 text-fg text-xs xs:text-sm outline-none w-full"

  html.div([attribute.class("mb-3 xs:mb-4")], [
    html.div([attribute.class("flex items-center gap-1 xs:gap-1.5 mb-1.5")], [
      view_entry_type_button("A", record.A, draft.type_, index),
      view_entry_type_button("AAAA", record.Aaaa, draft.type_, index),
      view_entry_type_button("CNAME", record.Cname, draft.type_, index),
      html.div([attribute.class("flex-1")], []),
      case can_remove {
        True ->
          html.button(
            [
              attribute.type_("button"),
              event.on_click(UserRemovedEntry(index)),
              attribute.class(
                "text-subtle hover:text-red-400 transition-colors cursor-pointer text-sm xs:text-base leading-none",
              ),
            ],
            [html.text("×")],
          )
        False -> element.none()
      },
    ]),
    html.div([attribute.class("flex gap-1.5 xs:gap-2")], [
      html.div([attribute.class("flex-1 min-w-0 flex flex-col gap-1")], [
        html.input([
          attribute.type_("text"),
          attribute.value(draft.value),
          attribute.placeholder(value_placeholder(draft.type_)),
          event.on_input(UserChangedEntryValue(index, _)),
          attribute.class(value_input_class),
        ]),
        view_field_error(draft.value_error),
      ]),
      html.div([attribute.class("w-14 xs:w-16 sm:w-20 flex flex-col gap-1")], [
        html.input([
          attribute.type_("number"),
          attribute.value(draft.ttl),
          attribute.attribute("min", "1"),
          attribute.attribute("max", "86400"),
          event.on_input(UserChangedEntryTtl(index, _)),
          attribute.class(ttl_input_class),
        ]),
        view_field_error(draft.ttl_error),
      ]),
    ]),
  ])
}

fn view_entry_type_button(
  label: String,
  type_: record.RecordType,
  active: record.RecordType,
  index: Int,
) -> Element(Message) {
  html.button(
    [
      attribute.type_("button"),
      event.on_click(UserChangedEntryType(index, type_)),
      attribute.class(
        "px-1.5 py-0.5 xs:px-2 xs:py-1 rounded text-2xs xs:text-xs font-medium transition-colors cursor-pointer "
        <> case type_ == active {
          True -> "bg-accent text-fg"
          False -> "bg-elevated text-subtle hover:text-fg"
        },
      ),
    ],
    [html.text(label)],
  )
}

fn value_placeholder(type_: record.RecordType) -> String {
  case type_ {
    record.A -> "192.168.1.1"
    record.Aaaa -> "::1"
    record.Cname -> "target.domain"
  }
}

fn view_domain_card(
  group: record.DomainGroup,
  confirming_delete: Option(String),
  global_busy: Bool,
) -> Element(Message) {
  let dimmed =
    global_busy
    || case confirming_delete {
      Some(pending) -> pending != group.name
      None -> False
    }

  let card_class =
    "bg-surface border border-elevated rounded-xl p-3 xs:p-5 sm:p-6 md:p-8 transition-opacity duration-200"
    <> case dimmed {
      True -> " opacity-25 pointer-events-none"
      False -> ""
    }

  html.div([attribute.class(card_class)], [
    html.div(
      [
        attribute.class(
          "flex items-start justify-between gap-2 mb-2 xs:mb-3 sm:mb-4",
        ),
      ],
      [
        html.h2(
          [
            attribute.class(
              "font-semibold text-xs xs:text-sm sm:text-base md:text-lg break-all",
            ),
          ],
          [html.text(group.name)],
        ),
        html.div(
          [attribute.class("flex items-center gap-1.5 xs:gap-2 shrink-0")],
          [
            html.button(
              [
                attribute.disabled(dimmed),
                event.on_click(UserClickedEdit(group.name)),
                attribute.class(
                  "text-subtle hover:text-fg transition-colors cursor-pointer",
                ),
              ],
              [view_pencil_icon()],
            ),
            view_card_delete_button(group.name, confirming_delete, dimmed),
          ],
        ),
      ],
    ),
    html.div(
      [attribute.class("space-y-1 xs:space-y-1.5 sm:space-y-2")],
      list.map(group.records, view_entry_row),
    ),
  ])
}

fn view_entry_row(entry: record.RecordEntry) -> Element(Message) {
  let #(type_label, value) = case entry {
    record.AEntry(ip:, ..) -> #("A", ip.ipv4_to_string(ip))
    record.AaaaEntry(ip:, ..) -> #("AAAA", ip.ipv6_to_string(ip))
    record.CnameEntry(target:, ..) -> #("CNAME", target)
  }
  let ttl_label = int.to_string(entry.ttl) <> "s"

  html.div(
    [
      attribute.class(
        "grid grid-cols-[2.5rem_1fr_auto] xs:grid-cols-[3.5rem_1fr_auto] sm:grid-cols-[4.5rem_1fr_auto] gap-x-2 xs:gap-x-3 sm:gap-x-4 items-baseline",
      ),
    ],
    [
      html.span(
        [
          attribute.class(
            "text-subtle font-mono text-2xs xs:text-xs sm:text-sm",
          ),
        ],
        [html.text(type_label)],
      ),
      html.span(
        [
          attribute.class(
            "text-muted font-mono text-2xs xs:text-xs sm:text-sm break-all",
          ),
        ],
        [html.text(value)],
      ),
      html.span(
        [attribute.class("text-subtle text-2xs xs:text-xs whitespace-nowrap")],
        [html.text(ttl_label)],
      ),
    ],
  )
}

fn view_card_delete_button(
  domain: String,
  confirming_delete: Option(String),
  disabled: Bool,
) -> Element(Message) {
  case confirming_delete {
    Some(pending) if pending == domain ->
      html.button(
        [
          attribute.disabled(disabled),
          event.on_click(UserConfirmedDelete(domain)),
          attribute.class("text-red-300 transition-colors cursor-pointer"),
        ],
        [view_trash_icon()],
      )
    Some(_other_domain) | None ->
      html.button(
        [
          attribute.disabled(disabled),
          event.on_click(UserClickedDelete(domain)),
          attribute.class(
            "text-subtle hover:text-red-400 transition-colors cursor-pointer",
          ),
        ],
        [view_trash_icon()],
      )
  }
}

fn view_pencil_icon() -> Element(msg) {
  svg.svg(
    [
      attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
      attribute.attribute("fill", "currentColor"),
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.class("size-3 xs:size-3.5 sm:size-4"),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M12.854.146a.5.5 0 0 0-.707 0L10.5 1.793 14.207 5.5l1.647-1.646a.5.5 0 0 0 0-.708l-3-3zm.646 6.061L9.793 2.5 3.293 9H3.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.207l6.5-6.5zm-7.468 7.468A.5.5 0 0 1 6 13.5V13h-.5a.5.5 0 0 1-.5-.5V12h-.5a.5.5 0 0 1-.5-.5V11h-.5a.5.5 0 0 1-.5-.5V10h-.5a.499.499 0 0 1-.175-.032l-.179.178a.5.5 0 0 0-.11.168l-2 5a.5.5 0 0 0 .65.65l5-2a.5.5 0 0 0 .168-.11l.178-.178z",
        ),
      ]),
    ],
  )
}

fn view_trash_icon() -> Element(msg) {
  svg.svg(
    [
      attribute.attribute("xmlns", "http://www.w3.org/2000/svg"),
      attribute.attribute("fill", "currentColor"),
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.class("size-3 xs:size-3.5 sm:size-4"),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5m2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5m3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0z",
        ),
      ]),
      svg.path([
        attribute.attribute(
          "d",
          "M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1H6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1h3.5a1 1 0 0 1 1 1zM4.118 4 4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4zM2.5 3h11V2h-11z",
        ),
      ]),
    ],
  )
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
