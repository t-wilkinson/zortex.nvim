-- notifications/providers/ses.lua - AWS SES email provider
local base = require("zortex.notifications.providers.base")

local function format_email_body(title, message, options)
	-- Format email body with optional HTML
	local body = {
		text = string.format("%s\n\n%s", title, message),
		html = nil,
	}

	if options.format == "digest" and options.html then
		-- For digest format, wrap the provided HTML content
		body.html = string.format(
			[[
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #333; line-height: 1.6; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background: #1a1a1a; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0; }
        .content { background: #f9f9f9; padding: 20px; border-radius: 0 0 8px 8px; }
        .day-section { background: white; padding: 15px; margin: 10px 0; border-radius: 6px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .day-header { font-weight: bold; color: #2c3e50; margin-bottom: 10px; font-size: 18px; }
        .entry { padding: 8px 0; border-bottom: 1px solid #eee; }
        .entry:last-child { border-bottom: none; }
        .time { color: #7f8c8d; font-weight: 500; }
        .task { color: #3498db; }
        .event { color: #e74c3c; }
        .notification { color: #f39c12; font-weight: bold; }
        .footer { text-align: center; color: #7f8c8d; font-size: 12px; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>%s</h1>
        </div>
        <div class="content">
            %s
        </div>
        <div class="footer">
            Sent by Zortex • <a href="mailto:unsubscribe@%s?subject=Unsubscribe">Unsubscribe</a>
        </div>
    </div>
</body>
</html>]],
			title:gsub("%%", "%%%%"), -- Escape % in title
			options.html, -- The HTML content is already formatted
			options.domain or "example.com"
		)
	elseif options.html then
		-- Use provided HTML as-is
		body.html = options.html
	end

	return body
end

local function send(title, message, options, config)
	if not config.region or not config.from_email then
		return false, "AWS SES region and from_email must be configured"
	end

	options = options or {}
	local to_email = options.to_email or config.default_to_email
	if not to_email then
		return false, "No recipient email specified"
	end

	local body = format_email_body(title, message, options)

	-- Build AWS CLI command
	local email_json = {
		Source = config.from_email,
		Destination = {
			ToAddresses = type(to_email) == "table" and to_email or { to_email },
		},
		Message = {
			Subject = {
				Data = title,
				Charset = "UTF-8",
			},
			Body = {},
		},
	}

	if body.text then
		email_json.Message.Body.Text = {
			Data = body.text,
			Charset = "UTF-8",
		}
	end

	if body.html then
		email_json.Message.Body.Html = {
			Data = body.html,
			Charset = "UTF-8",
		}
	end

	local json_data = vim.fn.json_encode(email_json)
	local tmpfile = vim.fn.tempname()
	vim.fn.writefile(vim.split(json_data, "\n"), tmpfile)

	local cmd = string.format(
		"aws ses send-email --region %s --cli-input-json %s",
		vim.fn.shellescape(config.region),
		"file://" .. tmpfile -- Use the file URI scheme
	)

	local success, result
	local cleanup = function()
		vim.fn.delete(tmpfile)
	end

	-- Execute the command
	local handle = io.popen(cmd .. " 2>&1")
	if handle then
		result = handle:read("*a")
		success = handle:close()

		if success then
			local ok, response = pcall(vim.fn.json_decode, result)
			if ok and response.MessageId then
				cleanup() -- Clean up on success
				return true, response.MessageId
			else
				cleanup() -- Clean up on failure
				return false, "Failed to send email: " .. result
			end
		else
			cleanup() -- Clean up on error
			return false, "AWS CLI error: " .. result
		end
	end

	cleanup() -- Clean up if popen fails
	return false, "Failed to execute AWS CLI"
end

return base.create_provider("ses", {
	send = send,

	test = function(config)
		return send("Zortex Test Email", "This is a test email from Zortex notifications.", {
			html = "<p>This is a <strong>test email</strong> from Zortex notifications.</p>",
		}, config or {
			region = "us-east-1",
			from_email = "noreply@example.com",
			default_to_email = "test@example.com",
		})
	end,
})
