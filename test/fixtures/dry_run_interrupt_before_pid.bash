# shellcheck shell=bash
# Inject SIGINT immediately before the wrapper records the PID of its already-started child.
trap '
  if [[ "$BASH_COMMAND" == "context_bot_child_pid=\$!" ]]; then
    trap - DEBUG
    kill -INT "$$"
  fi
' DEBUG
