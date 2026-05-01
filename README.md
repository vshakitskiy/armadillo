# Armadillo

A DNS server for my local network, powered by Gleam.

## The Vision

The plan is to build a recursive resolver with local overrides. It will use SQLite for persistent record storage and ETS for in-memory caching. Management will happen via a simple HTTP API.