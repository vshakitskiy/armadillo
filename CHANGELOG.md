## Unreleased

- Simplify the code used to edit domains and process DNS and API requests
- Return a DNS failure response for circular domain aliases or alias chains 
  longer than 32 records
- Reject configurations with more than one alias record for a domain
- Replace old cached records for a domain and record type with the records 
  returned by the upstream DNS server
- Do not cache truncated and incomplete DNS responses
- Keep DNS responses consistent with saved domain records during concurrent 
  edits
- Prevent upstream cache updates or expiration from changing locally configured 
  DNS records
- Disable controls behind an open popup in the UI
- Reject invalid domain names, alias targets and cache durations before saving
- Continue serving the previous DNS records if saving an edit fails
- Keep the existing zone file unchanged if writing its replacement fails
- Reject malformed DNS names that could block request processing
- Fix corrupted domain names in forwarded DNS responses that use name 
  compression
- Reject DNS queries containing multiple questions and DNS operations the server 
  does not support
- Reject invalid IP addresses and accept compressed IPv6 addresses (like `::1`)
- Treat DNS names such as `Host.LAN`, `host.lan` and `host.lan.` as the same 
  name
- Support upstream DNS servers with IPv6 addresses and return a DNS failure 
  response if forwarding fails
- Use random query IDs and accept upstream DNS responses only from the expected 
  server and for the matching query
- Prevent incorrect decreases in the zone file's version number after repeated 
  edits or clock changes
- Allow editing and deleting domain names containing URL characters such as `/`, 
  `?`, `#`, `%` and `+`
- Disable domain changes in the UI while the existing domain list is loading

## v2.0.0 - 28.06.2026

- Check DNS response IDs to help prevent forged responses from being cached
- Support IPv4, IPv6 and domain alias records
- Store DNS records in a zone file instead of SQLite with a configurable file 
  path
- Display domain records as cards instead of table rows
- Improve error display
- Expand deployment instructions

## v1.0.0 - 12.06.2026

- Initial release
