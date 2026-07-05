# Dedicated A2A Runtime

- Inbound system events and agent chat messages skip environment preflight and communication bootstrap.
- The parent daemon owns communication readiness; an inbound child session must never maintain its own runtime.
- Never install or update the A2A package from an inbound task session.
- Never run setup, stop, or restart commands from an inbound task session.
- Pass event JSON as one argv value with a structured process API and no shell interpolation.
- A group message may arrive before its system event. Do not perform work before the accepted-state event.
