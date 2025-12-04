-- differential_validator.lua
-- Compare replay results against original capture using differential testing

local DifferentialValidator = {}

-- Validate replay results against original capture
-- @param original: Original test object (from JSON)
-- @param replay: Replay results
-- @return: Validation results table
function DifferentialValidator.validate(original, replay)
    local results = {
        overall_success = false,
        command_sequence_match = false,
        command_results_match = false,
        log_output_match = false,
        errors = {}
    }

    -- 1. Compare command sequences
    local cmd_seq_result = DifferentialValidator.compare_command_sequences(
        original.command_log,
        replay.command_log
    )
    results.command_sequence_match = cmd_seq_result.match
    if not cmd_seq_result.match then
        table.insert(results.errors, cmd_seq_result.error)
    end

    -- 2. Compare command results
    local cmd_res_result = DifferentialValidator.compare_command_results(
        original.command_log,
        replay.command_log
    )
    results.command_results_match = cmd_res_result.match
    if not cmd_res_result.match then
        table.insert(results.errors, cmd_res_result.error)
    end

    -- 3. Compare log output (warnings/errors only)
    local log_result = DifferentialValidator.compare_log_output(
        original.log_output,
        replay.log_output
    )
    results.log_output_match = log_result.match
    if not log_result.match then
        table.insert(results.errors, log_result.error)
    end

    -- Overall success: all validations pass
    results.overall_success =
        results.command_sequence_match and
        results.command_results_match and
        results.log_output_match

    return results
end

-- Compare command sequences (names and order)
function DifferentialValidator.compare_command_sequences(original, replay)
    if #original ~= #replay then
        return {
            match = false,
            error = string.format(
                "Command count mismatch: original=%d, replay=%d",
                #original, #replay
            )
        }
    end

    for i, orig_cmd in ipairs(original) do
        local replay_cmd = replay[i]
        if orig_cmd.command ~= replay_cmd.command then
            return {
                match = false,
                error = string.format(
                    "Command #%d mismatch: original='%s', replay='%s'",
                    i, orig_cmd.command, replay_cmd.command
                )
            }
        end
    end

    return {match = true}
end

-- Compare command results (success/failure, error messages)
function DifferentialValidator.compare_command_results(original, replay)
    for i, orig_cmd in ipairs(original) do
        local replay_cmd = replay[i]

        -- Compare success/failure
        local orig_success = orig_cmd.result and orig_cmd.result.success
        local replay_success = replay_cmd.result and replay_cmd.result.success

        if orig_success ~= replay_success then
            return {
                match = false,
                error = string.format(
                    "Command #%d '%s' result mismatch: original=%s, replay=%s",
                    i,
                    orig_cmd.command,
                    tostring(orig_success),
                    tostring(replay_success)
                )
            }
        end

        -- Compare error messages (if both failed)
        if not orig_success and not replay_success then
            local orig_error = orig_cmd.result.error_message or ""
            local replay_error = replay_cmd.result.error_message or ""

            -- Fuzzy match: check if key parts of error message match
            -- (exact match is too brittle - line numbers may differ)
            if not DifferentialValidator.error_messages_match(orig_error, replay_error) then
                return {
                    match = false,
                    error = string.format(
                        "Command #%d '%s' error message mismatch:\n  Original: %s\n  Replay: %s",
                        i,
                        orig_cmd.command,
                        orig_error,
                        replay_error
                    )
                }
            end
        end
    end

    return {match = true}
end

-- Compare log output (warnings and errors only)
function DifferentialValidator.compare_log_output(original, replay)
    -- Filter to warnings and errors only (info messages may vary)
    local function filter_important(logs)
        local filtered = {}
        for _, log in ipairs(logs) do
            if log.level == "warning" or log.level == "error" then
                table.insert(filtered, log)
            end
        end
        return filtered
    end

    local orig_important = filter_important(original)
    local replay_important = filter_important(replay)

    if #orig_important ~= #replay_important then
        return {
            match = false,
            error = string.format(
                "Log count mismatch (warnings/errors): original=%d, replay=%d",
                #orig_important, #replay_important
            )
        }
    end

    -- Compare messages (fuzzy match)
    for i, orig_log in ipairs(orig_important) do
        local replay_log = replay_important[i]

        if orig_log.level ~= replay_log.level then
            return {
                match = false,
                error = string.format(
                    "Log #%d level mismatch: original='%s', replay='%s'",
                    i, orig_log.level, replay_log.level
                )
            }
        end

        -- Fuzzy match messages
        if not DifferentialValidator.log_messages_match(orig_log.message, replay_log.message) then
            return {
                match = false,
                error = string.format(
                    "Log #%d message mismatch:\n  Original: %s\n  Replay: %s",
                    i, orig_log.message, replay_log.message
                )
            }
        end
    end

    return {match = true}
end

-- Fuzzy match for error messages (ignores line numbers, small differences)
function DifferentialValidator.error_messages_match(msg1, msg2)
    -- Exact match
    if msg1 == msg2 then
        return true
    end

    -- Normalize: lowercase, remove line numbers, remove timestamps
    local function normalize(msg)
        msg = msg:lower()
        msg = msg:gsub(":%d+:", ":")  -- Remove :123: line numbers
        msg = msg:gsub("%d+ms", "Xms")  -- Normalize timing
        msg = msg:gsub("%d+%.%d+", "X")  -- Normalize numbers
        return msg
    end

    return normalize(msg1) == normalize(msg2)
end

-- Fuzzy match for log messages
function DifferentialValidator.log_messages_match(msg1, msg2)
    -- Same logic as error messages
    return DifferentialValidator.error_messages_match(msg1, msg2)
end

-- Generate a detailed diff report
function DifferentialValidator.generate_diff_report(validation_results)
    local lines = {}

    table.insert(lines, "=== Differential Validation Report ===")
    table.insert(lines, "")

    if validation_results.overall_success then
        table.insert(lines, "✓ All checks passed - replay matches original")
    else
        table.insert(lines, "✗ Validation failed - differences detected")
    end

    table.insert(lines, "")
    table.insert(lines, "Results:")
    table.insert(lines, string.format("  Command Sequence: %s",
        validation_results.command_sequence_match and "✓ Match" or "✗ Mismatch"))
    table.insert(lines, string.format("  Command Results:  %s",
        validation_results.command_results_match and "✓ Match" or "✗ Mismatch"))
    table.insert(lines, string.format("  Log Output:       %s",
        validation_results.log_output_match and "✓ Match" or "✗ Mismatch"))

    if #validation_results.errors > 0 then
        table.insert(lines, "")
        table.insert(lines, "Errors:")
        for i, error in ipairs(validation_results.errors) do
            table.insert(lines, string.format("  %d. %s", i, error))
        end
    end

    table.insert(lines, "")
    table.insert(lines, string.rep("=", 40))

    return table.concat(lines, "\n")
end

return DifferentialValidator
