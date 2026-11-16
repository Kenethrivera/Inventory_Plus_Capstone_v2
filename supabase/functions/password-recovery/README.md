# Password recovery deployment

Apply `database/phase_password_recovery.sql`, then `database/phase_password_recovery_email.sql`. Apply `database/phase_password_recovery_questions.sql` to enable the security-question option, followed by `database/phase_password_recovery_questions_status.sql` so the Admin profile can show its saved setup status. Deploy this Edge function afterward.

For a project that already has security questions deployed, apply `database/phase_password_recovery_three_questions.sql` before deploying the updated Edge function. Existing two-question challenges expire during the upgrade; saved questions and answer hashes remain in place.

Set these Edge Function secrets for email delivery using the existing EmailJS template:

- `EMAILJS_SERVICE_ID`
- `EMAILJS_TEMPLATE_ID`
- `EMAILJS_PUBLIC_KEY`

The template must send to `{{email}}` and display `{{otp_code}}`. `EMAILJS_PRIVATE_KEY` is optional when the EmailJS account requires a private key for server requests. `EMAILJS_ORIGIN` is optional; it defaults to the `http://localhost` origin used by the earlier Flutter email implementation. Copy the existing EmailJS values from your local configuration into Supabase secrets. Do not commit their values.

SMS continues to use `TEXTBEE_API_KEY` and optional `TEXTBEE_DEVICE_ID`.
