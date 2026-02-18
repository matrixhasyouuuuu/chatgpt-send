# shellcheck shell=bash
# Main CLI flow orchestrator for chatgpt_send.
run_chatgpt_send_main() {
  chatgpt_send_parse_args "$@"
  chatgpt_send_validate_transport
  chatgpt_send_handle_early_commands
  chatgpt_send_run_send_pipeline
}
