// Receives feedback from the SMBDrop iOS app and emails it via Resend.
// The app sends: { kind, message, contact?, appVersion, build, systemVersion }

const MAX_BODY_BYTES = 16 * 1024;
const KINDS = new Set(["feature", "problem", "other"]);

// Not a security boundary — just keeps drive-by bots from generating email.
const CLIENT_HEADER = "smbdrop-ios-v1";

export default {
	async fetch(request, env) {
		if (request.method !== "POST" || new URL(request.url).pathname !== "/feedback") {
			return json({ error: "not found" }, 404);
		}
		if (request.headers.get("x-smbdrop-client") !== CLIENT_HEADER) {
			return json({ error: "forbidden" }, 403);
		}

		const raw = await request.text();
		if (raw.length > MAX_BODY_BYTES) {
			return json({ error: "payload too large" }, 413);
		}

		let payload;
		try {
			payload = JSON.parse(raw);
		} catch {
			return json({ error: "invalid JSON" }, 400);
		}

		const kind = KINDS.has(payload.kind) ? payload.kind : "other";
		const message = typeof payload.message === "string" ? payload.message.trim() : "";
		if (!message) {
			return json({ error: "message is required" }, 400);
		}

		const contact = clean(payload.contact);
		const appVersion = clean(payload.appVersion) || "?";
		const build = clean(payload.build) || "?";
		const systemVersion = clean(payload.systemVersion) || "?";

		const subjectPrefix = {
			feature: "Feature request",
			problem: "Problem report",
			other: "Feedback",
		}[kind];

		const lines = [
			message,
			"",
			"—",
			`Type: ${subjectPrefix}`,
			`Reply-to: ${contact || "not provided"}`,
			`App: SMBDrop ${appVersion} (${build}) · iOS ${systemVersion}`,
		];

		const email = {
			from: env.FEEDBACK_FROM,
			to: [env.FEEDBACK_TO],
			subject: `[SMBDrop] ${subjectPrefix}`,
			text: lines.join("\n"),
		};
		// Only trust user-supplied reply-to when it looks like an address.
		if (contact && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contact)) {
			email.reply_to = contact;
		}

		const response = await fetch("https://api.resend.com/emails", {
			method: "POST",
			headers: {
				Authorization: `Bearer ${env.RESEND_API_KEY}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify(email),
		});

		if (!response.ok) {
			console.error("Resend rejected the email", response.status, await response.text());
			return json({ error: "delivery failed" }, 502);
		}
		return json({ ok: true });
	},
};

function clean(value) {
	return typeof value === "string" ? value.trim().slice(0, 200) : "";
}

function json(body, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "Content-Type": "application/json" },
	});
}
