# Counter Watch

Live check-in tracking for service counters. Agents sign in on their phone or computer and check in at their counter; the app confirms they're physically there using the device's location, and keeps confirming every minute. The admin gets a live board showing which counters are **staffed**, which **need checking**, and which are **unmanned**, and for how long.

This version runs with no server of your own: the page is hosted free on **GitHub Pages**, and logins and data live in a free **Supabase** database.

## Set it up (about 10 minutes, once)

1. **Create the database.** Sign up at [supabase.com](https://supabase.com) and create a project (pick the Singapore region if your team is there). Open **SQL Editor → New query**, paste all of [`schema.sql`](schema.sql), and press **Run**. The result at the bottom is your **setup code**. Keep it private.
2. **Connect the page.** In Supabase open **Project Settings → API** (or **Connect**). Copy the **Project URL** and the **anon public** key into [`config.js`](config.js) and commit. The anon key is designed to be public; the database only lets it call this app's functions.
3. **Open the app** at `https://<your-github-name>.github.io/<repo-name>/`. Enter the setup code, then create the admin account.
4. **Add counters** (stand at each one and press *Use my current location*, or click the map) and **agents** (Team page: username + temporary password). Send agents the link.

To find the setup code again, run `select setup_code from cw_settings;` in the SQL Editor.

## How the board decides

| Counter shows | When |
|---|---|
| **Staffed** | At least one checked-in agent's location was confirmed inside the counter's radius in the last 3 minutes |
| **Check** | Someone is checked in, but their last location was outside the radius (*Away from counter*) or nothing has come in for 3+ minutes (*No signal*) |
| **Unmanned** | Nobody is checked in. The card shows how long it's been empty |

- **Check-in** needs the agent within the counter's radius (default 50 m) and a location accurate to ±150 m or better. Up to 50 m of the phone's stated accuracy is given the benefit of the doubt.
- **While checked in**, the page sends the location every minute and asks the phone to keep the screen on. If the screen locks or the page is closed, checks pause and the counter shows *No signal*.
- **Automatic check-out:** after 30 minutes with no location, the agent is checked out at the last moment they were confirmed.
- Sign-in locks for 15 minutes after 5 wrong passwords for one username (or from one address). An admin password reset clears it for that person.

The numbers are in `cw_config()` at the top of `schema.sql`. Change them there and run the file again; it keeps your data.

## Who can do what

| | Agent | Admin |
|---|---|---|
| Check in / out at a counter | ✓ | ✓ |
| Live board, log, location history | | ✓ |
| Add counters, manage people, check someone out | | ✓ |

## How it's secured

The page is public, so all the rules live in the database. Every table has row-level security on with no policies, so the public key can't read or change any table directly; it can only call the `cw_*` functions, and each one checks the caller's sign-in and role. Passwords are stored as bcrypt hashes, sign-in tokens only as SHA-256 hashes, and check-in times come from the database clock, not the phone.

## Good to know

- **Free Supabase projects pause after 7 days without any use.** Daily use keeps it awake; if it pauses, press *Restore* in the Supabase dashboard. Paid plans don't pause.
- **Accuracy indoors.** Phone GPS indoors is often off by 10–50 m; laptops locate by Wi-Fi and can be worse. Counters closer than about 30 m apart can't be told apart reliably.
- **It's a strong check, not proof.** Browser location can be faked. The log keeps every reading and the device used for each check-in.
- **Tell your agents.** Location is recorded once a minute only while someone is checked in. Check your local workplace-privacy rules (e.g. PDPA) before you start.
- **Backups:** Supabase → Database → Backups, or export tables from the Table Editor.
