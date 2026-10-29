## Unreleased

- Return a DNS error for CNAME loops and excessively long alias chains
- Reject multiple CNAME records for the same domain
- Fix upstream DNS replies leaving outdated addresses in the cache
- Avoid caching incomplete upstream replies
- Fix concurrent edits leaving DNS records out of sync with the zone file
- Prevent cached upstream records from overwriting or expiring local records
- Disable background controls in the UI while a popup is open
- Validate edited domain names, CNAME targets and TTL values before saving
- Keep zone records unchanged when writing the zone file fails
- Prevent failed or interrupted writes from leaving incomplete zone files
- Reject malformed DNS names and compression loops
- Forward upstream DNS replies without corrupting compressed record names
- Reject multiple questions in DNS queries and unsupported operations

## v2.0.0 - 28.06.2026

- Add id checking of the DNS packets, preventing cache poisoning vulnerability
- Allow different record types, for now its A, AAAA and CNAME
- Replace sqlite with zone file, expose option for the zone file path
- Change table design to card layout
- Better errors display
- Expand deployment guide

## v1.0.0 - 12.06.2026

- Initial release
