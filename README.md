# Brightwell Premium Plan Simulation (Cedar Valley Health)

Fictional classroom demo. Stack: Supabase (database, security rules, scheduler, Google sign-in), GitHub, Netlify. Two files hold everything: `index.html` and `supabase/schema.sql`. No build step.

## Setup (about 20 minutes)

1. **Supabase**: create a project. Open Database > Extensions and enable `pg_cron`. Open SQL Editor, paste all of `supabase/schema.sql`, and run it.
2. **Keys**: Project Settings > API. Paste the Project URL and anon key into the top of `index.html` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`).
3. **GitHub**: create a repo and push this folder.
4. **Netlify**: Add new site > Import from GitHub. Leave the build command empty and set the publish directory to `.`. Copy the site URL.
5. **Google sign-in**: in Google Cloud Console create an OAuth client (Web). Add the authorised redirect URI `https://YOUR-PROJECT.supabase.co/auth/v1/callback`. In Supabase, Authentication > Providers > Google, paste the client ID and secret. In Authentication > URL Configuration, set Site URL to your Netlify URL and add it to Redirect URLs.

## Test accounts

Sign in with any Google account. It starts as a Learner (CV-001). Use **Switch demo role** to become Kevin, Lisa, Angela, or a learner with any staff ID. The role is stored in the database, and every action checks it there. To turn switching off after the demo: `update settings set value='off' where key='demo_mode';`

## Demo script (maps to the brief)

1. Sign in, then switch to **Kevin**. Open **Issue queue**: CV-017 Basic Life Support is flagged *Missing certificate* while the course still shows *Completed*. CV-005 shows an overdue course.
2. Kevin: **Start review**, then in the tracker **Upload certificate**. Evidence becomes *Awaiting verification*; the issue becomes *Under review*.
3. Optional invalid case: upload a name like `LG-003_C2.pdf`. Lisa's approval is refused and she can reject it (issue reopens).
4. Switch to **Lisa**: **Verify**. Only that issue becomes *Resolved*; CV-005 stays flagged. **Activity** shows actor and time.
5. **Reports**: **Run report now**, then download. CV-017 is under VERIFIED and CV-005 under EXCEPTION. Use **Test scheduled Friday run** (a second saved snapshot), and **Test failed run** (shows FAILED). Earlier CSVs stay unchanged.
6. **Analytics**: verified +1, missing −1. Filter by facility, role, group (incoming staff have a June 2027 due date).
7. Switch to **Angela**: she sees analytics and reports only. Click **Try restricted action**: the database blocks it.

## Rules

- Course status: Not started / In progress / Completed. *Overdue* is a separate flag (not completed and past due).
- Certificate status: Missing / Awaiting verification / Verified / Rejected. Only Lisa can verify, and never automatically.
- Issue status: Flagged → Under review → Resolved (Reopened if rejected or changed later). It resolves only when the condition is fixed.
- Flags: *Incomplete* when not completed and due within 30 days; *Overdue* when past due; *Certificate* when completed but evidence is not verified.
- Checks run on every record change and hourly (including weekdays). Friday report: an hourly cron job runs at the Ohio hour in `settings.report_hour` (default 17), DST-safe. Change it with `update settings set value='9' where key='report_hour';`
- Dashboard rates use required course assignments, not people.

## QA checklist

- [ ] Completed course with no certificate is flagged, course stays Completed
- [ ] Upload leaves evidence Awaiting verification
- [ ] Mismatched certificate cannot be verified
- [ ] Verify resolves only the certificate issue; overdue issue remains
- [ ] Report after verification includes CV-017 as VERIFIED and CV-005 as EXCEPTION
- [ ] Failed test run shows FAILED; older CSVs unchanged
- [ ] Executive and Learner writes are blocked by the database
- [ ] Analytics and filters match the tracker

## Simulated or incomplete

Mock Google-based sign-in (not hospital SSO); certificate "upload" records a file name only (no file storage); the Friday run can be tested on demand but the real schedule needs an actual Friday; no regulator submission, notifications or CRM. All data is invented. No claims about savings or accreditation.

## Look and images

Sky blue, light pink and white theme. Photos live in `assets/` (login screen, analytics, learner view, issue queue, reports). The issue-queue photo is cropped to hide the RCSI crests on the uniforms; swap it for a neutral photo if you prefer. **View certificate** opens a redesigned fictional Cedar Valley certificate generated from each record (status stamp, certificate file, verification code, mismatch warning, Verify/Reject for Lisa, Print).
