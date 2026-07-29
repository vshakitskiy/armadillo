import armadillo/shared/ip
import armadillo/shared/records
import gleam/dynamic/decode
import gleam/function
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import rsvp

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

type EntryDraft {
  EntryDraft(
    type_: records.RecordType,
    value: String,
    ttl: String,
    value_error: Option(String),
    ttl_error: Option(String),
  )
}

fn default_entries() -> List(EntryDraft) {
  [
    EntryDraft(
      type_: records.A,
      value: "",
      ttl: "300",
      value_error: None,
      ttl_error: None,
    ),
  ]
}

type Model {
  Model(
    domains: List(records.DomainGroup),
    loading: Bool,
    saving: Bool,
    error: Option(String),
    popup: Popup,
    deleting: Option(String),
  )
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
  Model(
    domains: [],
    loading: True,
    saving: False,
    error: None,
    popup: Hidden,
    deleting: None,
  )
  |> pair.new(api_fetch_domains(ApiFetchReturned))
}

fn api_fetch_domains(
  on_response: fn(Result(List(records.DomainGroup), rsvp.Error(String))) ->
    Message,
) -> effect.Effect(Message) {
  decode.list(of: records.domain_group_decoder())
  |> rsvp.expect_json(on_response)
  |> rsvp.get("/api/domains", _)
}

fn api_insert_domain(
  group: records.DomainGroup,
  on_response: fn(
    records.DomainGroup,
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(on_response(group, _))
  |> rsvp.post("/api/domains", records.domain_group_to_json(group), _)
}

fn api_put_domain(
  name: String,
  entries: List(records.RecordEntry),
  on_response: fn(
    String,
    List(records.RecordEntry),
    Result(response.Response(String), rsvp.Error(String)),
  ) -> Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(on_response(name, entries, _))
  |> rsvp.put(
    "/api/domains/" <> name,
    json.array(entries, records.record_entry_to_json),
    _,
  )
}

fn api_delete_domain(
  name: String,
  on_response: fn(String, Result(response.Response(String), rsvp.Error(String))) ->
    Message,
) -> effect.Effect(Message) {
  rsvp.expect_ok_response(on_response(name, _))
  |> rsvp.delete("/api/domains/" <> name, json.object([]), _)
}

type Message {
  ApiFetchReturned(Result(List(records.DomainGroup), rsvp.Error(String)))

  UserClosedPopup
  PopupAnimationEnded

  UserClickedInsert
  UserChangedInsertDomain(String)
  UserSubmittedInsert
  ApiInsertReturned(
    group: records.DomainGroup,
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserClickedEdit(String)
  UserSubmittedEdit
  ApiPutReturned(
    domain: String,
    entries: List(records.RecordEntry),
    result: Result(response.Response(String), rsvp.Error(String)),
  )

  UserChangedEntryType(Int, records.RecordType)
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
  use entry, i <- list.index_map(entries)
  case i == index {
    True -> callback(entry)
    False -> entry
  }
}

fn validate_entry(
  draft: EntryDraft,
) -> Result(records.RecordEntry, EntryDraft) {
  let value_result = case draft.type_ {
    records.A ->
      case ip.ipv4_from_string(draft.value) {
        Ok(ip) -> Ok(records.AEntry(ttl: 0, ip:))
        Error(Nil) -> Error("must be a valid IPv4 address")
      }
    records.Aaaa ->
      case ip.ipv6_from_string(draft.value) {
        Ok(ip) -> Ok(records.AaaaEntry(ttl: 0, ip:))
        Error(Nil) -> Error("must be a valid IPv6 address")
      }
    records.Cname ->
      case string.is_empty(string.trim(draft.value)) {
        True -> Error("must not be blank")
        False -> Ok(records.CnameEntry(ttl: 0, target: draft.value))
      }
  }

  let ttl_result = case int.parse(draft.ttl) {
    Ok(n) if n > 0 && n <= 86_400 -> Ok(n)
    Ok(n) if n > 86_400 -> Error("must be ≤ 86400 (1 day)")
    Ok(_) -> Error("must be a positive number")
    Error(Nil) -> Error("must be a number")
  }

  case value_result, ttl_result {
    Ok(records.AEntry(ip:, ..)), Ok(ttl) -> Ok(records.AEntry(ttl:, ip:))
    Ok(records.AaaaEntry(ip:, ..)), Ok(ttl) -> Ok(records.AaaaEntry(ttl:, ip:))
    Ok(records.CnameEntry(target:, ..)), Ok(ttl) ->
      Ok(records.CnameEntry(ttl:, target:))
    _, _ ->
      EntryDraft(
        ..draft,
        value_error: case value_result {
          Error(msg) -> Some(msg)
          Ok(_) -> None
        },
        ttl_error: case ttl_result {
          Error(msg) -> Some(msg)
          Ok(_) -> None
        },
      )
      |> Error
  }
}

fn validate_entries(
  drafts: List(EntryDraft),
) -> Result(List(records.RecordEntry), List(EntryDraft)) {
  let results = list.map(drafts, validate_entry)
  let any_error = list.any(results, result.is_error)

  case any_error {
    False -> Ok(list.filter_map(results, function.identity))
    True ->
      list.zip(drafts, results)
      |> list.map(fn(pair) {
        let #(draft, result) = pair
        case result {
          Ok(_) -> draft
          Error(with_errors) -> with_errors
        }
      })
      |> Error
  }
}

fn entry_to_draft(entry: records.RecordEntry) -> EntryDraft {
  let #(type_, value) = case entry {
    records.AEntry(ip:, ..) -> #(records.A, ip.ipv4_to_string(ip))
    records.AaaaEntry(ip:, ..) -> #(records.Aaaa, ip.ipv6_to_string(ip))
    records.CnameEntry(target:, ..) -> #(records.Cname, target)
  }

  EntryDraft(
    type_:,
    value:,
    ttl: int.to_string(entry.ttl),
    value_error: None,
    ttl_error: None,
  )
}

fn api_error(err: rsvp.Error(String)) -> String {
  case err {
    rsvp.HttpError(resp) ->
      case string.is_empty(string.trim(resp.body)) {
        False -> resp.body
        True -> "Internal server error"
      }
    rsvp.NetworkError -> "Check your connection"
    _ -> "Something went wrong"
  }
}

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case model, message {
    model, ApiFetchReturned(Ok(domains)) -> #(
      Model(..model, domains:, loading: False),
      effect.none(),
    )
    model, ApiFetchReturned(Error(error)) -> {
      let error = api_error(error)
      #(Model(..model, loading: False, error: Some(error)), effect.none())
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
    _, PopupAnimationEnded -> #(model, effect.none())

    Model(popup: Hidden, ..), UserClickedInsert -> {
      let content =
        InsertContent(
          domain: "",
          domain_error: None,
          entries: default_entries(),
          form_error: None,
        )
      #(Model(..model, popup: Visible(content)), effect.none())
    }
    _, UserClickedInsert -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(entries:, ..)), ..),
      UserChangedInsertDomain(domain)
    -> {
      let content =
        InsertContent(domain:, domain_error: None, entries:, form_error: None)
      #(Model(..model, popup: Visible(content)), effect.none())
    }
    _, UserChangedInsertDomain(_) -> panic as "unreachable!"

    model, UserChangedEntryType(index, type_) -> {
      let popup = case model.popup {
        Visible(InsertContent(entries:, ..) as content) -> {
          let entries = {
            use draft <- update_entry_at(entries, index)
            EntryDraft(..draft, type_:, value_error: None)
          }
          Visible(InsertContent(..content, entries:))
        }
        Visible(EditContent(entries:, ..) as content) -> {
          let entries = {
            use draft <- update_entry_at(entries, index)
            EntryDraft(..draft, type_:, value_error: None)
          }
          Visible(EditContent(..content, entries:))
        }
        _ -> panic as "unreachable!"
      }
      #(Model(..model, popup:), effect.none())
    }

    model, UserChangedEntryValue(index, value) -> {
      let popup = case model.popup {
        Visible(InsertContent(entries:, ..) as content) -> {
          let entries = {
            use draft <- update_entry_at(entries, index)
            EntryDraft(..draft, value:, value_error: None)
          }
          Visible(InsertContent(..content, entries:))
        }
        Visible(EditContent(entries:, ..) as content) -> {
          let entries = {
            use draft <- update_entry_at(entries, index)
            EntryDraft(..draft, value:, value_error: None)
          }
          Visible(EditContent(..content, entries:))
        }
        _ -> panic as "unreachable!"
      }
      #(Model(..model, popup:), effect.none())
    }

    model, UserChangedEntryTtl(index, ttl) -> {
      let popup = case model.popup {
        Visible(InsertContent(entries:, ..) as content) -> {
          let entries = {
            use draft <- update_entry_at(entries, index)
            EntryDraft(..draft, ttl:, ttl_error: None)
          }
          Visible(InsertContent(..content, entries:))
        }
        Visible(EditContent(entries:, ..) as content) -> {
          let entries = {
            use draft <- update_entry_at(entries, index)
            EntryDraft(..draft, ttl:, ttl_error: None)
          }
          Visible(EditContent(..content, entries:))
        }
        _ -> panic as "unreachable!"
      }
      #(Model(..model, popup:), effect.none())
    }

    model, UserAddedEntry -> {
      let popup = case model.popup {
        Visible(InsertContent(entries:, ..) as content) -> {
          let entries = list.append(entries, default_entries())
          Visible(InsertContent(..content, entries:))
        }
        Visible(EditContent(entries:, ..) as content) -> {
          let entries = list.append(entries, default_entries())
          Visible(EditContent(..content, entries:))
        }
        _ -> panic as "unreachable!"
      }
      #(Model(..model, popup:), effect.none())
    }

    model, UserRemovedEntry(index) -> {
      let popup = case model.popup {
        Visible(InsertContent(entries:, ..) as content) -> {
          let lists = [list.take(entries, index), list.drop(entries, index + 1)]
          Visible(InsertContent(..content, entries: list.flatten(lists)))
        }
        Visible(EditContent(entries:, ..) as content) -> {
          let lists = [list.take(entries, index), list.drop(entries, index + 1)]
          Visible(EditContent(..content, entries: list.flatten(lists)))
        }
        _ -> panic as "unreachable!"
      }
      #(Model(..model, popup:), effect.none())
    }

    Model(popup: Visible(InsertContent(domain:, entries:, ..) as content), ..),
      UserSubmittedInsert
    -> {
      let domain = string.trim(domain)
      let domain_error = case string.is_empty(domain) {
        True -> Some("must not be blank")
        False -> None
      }

      let entries_result = validate_entries(entries)

      case domain_error, entries_result {
        None, Ok(records) -> {
          let content = InsertContent(..content, form_error: None)

          records.DomainGroup(name: domain, records:)
          |> api_insert_domain(ApiInsertReturned)
          |> pair.new(Model(..model, saving: True, popup: Visible(content)), _)
        }
        _, _ -> {
          let entries = result.unwrap_error(entries_result, entries)
          let content =
            InsertContent(domain:, domain_error:, entries:, form_error: None)

          #(Model(..model, popup: Visible(content)), effect.none())
        }
      }
    }
    _, UserSubmittedInsert -> panic as "unreachable!"

    Model(popup: Visible(InsertContent(..)), ..),
      ApiInsertReturned(group:, result: Ok(_))
    -> {
      let domains = list.append(model.domains, [group])
      #(Model(..model, domains:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Visible(InsertContent(..) as content), ..),
      ApiInsertReturned(group: _, result: Error(error))
    -> {
      let error = api_error(error)
      let popup = Visible(InsertContent(..content, form_error: Some(error)))
      #(Model(..model, saving: False, popup:), effect.none())
    }
    _, ApiInsertReturned(..) -> panic as "unreachable!"

    Model(popup: Hidden, ..), UserClickedEdit(domain) -> {
      case list.find(model.domains, fn(group) { group.name == domain }) {
        Ok(group) -> {
          let entries = list.map(group.records, entry_to_draft)
          let content = EditContent(domain:, entries:, form_error: None)
          #(Model(..model, popup: Visible(content)), effect.none())
        }
        Error(Nil) -> panic as "domain not found"
      }
    }
    _, UserClickedEdit(_) -> panic as "unreachable!"

    Model(
      popup: Visible(EditContent(domain:, entries:, ..) as edit_content),
      ..,
    ),
      UserSubmittedEdit
    -> {
      case validate_entries(entries) {
        Ok(valid_entries) -> {
          let content = EditContent(..edit_content, form_error: None)
          Model(..model, saving: True, popup: Visible(content))
          |> pair.new(api_put_domain(domain, valid_entries, ApiPutReturned))
        }
        Error(updated_entries) -> {
          let content =
            EditContent(domain:, entries: updated_entries, form_error: None)
          #(Model(..model, popup: Visible(content)), effect.none())
        }
      }
    }
    _, UserSubmittedEdit -> panic as "unreachable!"

    Model(popup: Visible(EditContent(..)), ..),
      ApiPutReturned(domain:, entries:, result: Ok(_))
    -> {
      let domains =
        list.map(model.domains, fn(group) {
          case group.name == domain {
            True -> records.DomainGroup(name: domain, records: entries)
            False -> group
          }
        })
      #(Model(..model, domains:, saving: False, popup: Hidden), effect.none())
    }
    Model(popup: Visible(EditContent(..) as content), ..),
      ApiPutReturned(domain: _, entries: _, result: Error(error))
    -> {
      let error = api_error(error)
      let popup = Visible(EditContent(..content, form_error: Some(error)))
      #(Model(..model, saving: False, popup:), effect.none())
    }
    _, ApiPutReturned(..) -> panic as "unreachable!"

    model, UserClickedDelete(domain) -> #(
      Model(..model, deleting: Some(domain)),
      delete_cancel_after(domain, 3000),
    )

    Model(popup: Visible(content), ..), UserClickedDeleteDomainFromEdit(domain)
    -> #(
      Model(..model, popup: Closing(content), deleting: Some(domain)),
      delete_cancel_after(domain, 3000),
    )
    _, UserClickedDeleteDomainFromEdit(_) -> panic as "unreachable!"

    model, DeleteCancelled(domain) ->
      case model.deleting {
        Some(pending) if pending == domain -> #(
          Model(..model, deleting: None),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    model, UserConfirmedDelete(domain) ->
      Model(..model, saving: True, deleting: None)
      |> pair.new(api_delete_domain(domain, ApiDeleteReturned))

    model, ApiDeleteReturned(domain:, result: Ok(_)) -> {
      let domains =
        list.filter(model.domains, fn(group) { group.name != domain })
      #(Model(..model, domains:, saving: False), effect.none())
    }
    model, ApiDeleteReturned(domain: _, result: Error(err)) -> {
      let error = Some(api_error(err))
      #(Model(..model, saving: False, error:), effect.none())
    }
  }
}

fn view_field_error(error: Option(String)) -> Element(msg) {
  case error {
    Some(msg) ->
      html.p([attribute.class("text-red-400 text-2xs xs:text-xs italic")], [
        html.text(msg),
      ])
    None -> element.none()
  }
}

fn input_border_state(error: Option(String)) -> String {
  case error {
    Some(_) -> "border-red-500"
    None -> "border-elevated focus:border-accent"
  }
}

fn view_entries_list(entries: List(EntryDraft)) -> Element(Message) {
  html.div([attribute.class("flex-1 min-h-0 overflow-y-auto")], [
    html.div(
      [],
      list.index_map(entries, fn(entry, index) {
        view_entry_draft(index, entry, list.length(entries) > 1)
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
            html.div(
              [
                attribute.class(
                  "flex flex-col gap-2 xs:gap-3 sm:gap-4 md:gap-5",
                ),
              ],
              list.map(model.domains, view_domain_card(
                _,
                model.deleting,
                global_busy,
              )),
            )
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
          _ -> decode.failure(UserClosedPopup, "")
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
      view_entry_type_button("A", records.A, draft.type_, index),
      view_entry_type_button("AAAA", records.Aaaa, draft.type_, index),
      view_entry_type_button("CNAME", records.Cname, draft.type_, index),
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
  type_: records.RecordType,
  active: records.RecordType,
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

fn value_placeholder(type_: records.RecordType) -> String {
  case type_ {
    records.A -> "192.168.1.1"
    records.Aaaa -> "::1"
    records.Cname -> "target.domain"
  }
}

fn view_domain_card(
  group: records.DomainGroup,
  deleting: Option(String),
  global_busy: Bool,
) -> Element(Message) {
  let dimmed = case deleting {
    Some(pending) if pending == group.name -> False
    Some(_) -> True
    None -> global_busy
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
                event.on_click(UserClickedEdit(group.name)),
                attribute.class(
                  "text-subtle hover:text-fg transition-colors cursor-pointer",
                ),
              ],
              [view_pencil_icon()],
            ),
            view_card_delete_button(group.name, deleting),
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

fn view_entry_row(entry: records.RecordEntry) -> Element(Message) {
  let #(type_label, value) = case entry {
    records.AEntry(ip:, ..) -> #("A", ip.ipv4_to_string(ip))
    records.AaaaEntry(ip:, ..) -> #("AAAA", ip.ipv6_to_string(ip))
    records.CnameEntry(target:, ..) -> #("CNAME", target)
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
  deleting: Option(String),
) -> Element(Message) {
  case deleting {
    Some(pending) if pending == domain ->
      html.button(
        [
          event.on_click(UserConfirmedDelete(domain)),
          attribute.class("text-red-300 transition-colors cursor-pointer"),
        ],
        [view_trash_icon()],
      )
    _ ->
      html.button(
        [
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
