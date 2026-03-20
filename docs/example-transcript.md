---
schema: openoats/v1
title: "Notification System: Scope and Launch Plan"
date: 2026-03-18T10:30:00+01:00
duration: 11
participants:
  - You
  - Them
recorder: Szymon Sypniewicz
tags:
  - product
  - notifications
  - launch
language: en
engine: parakeet-tdt-v2
app: meet
---

# Notification System: Scope and Launch Plan

## Summary

Discussed the scope and timeline for shipping the in-app notification system. The original plan included real-time push notifications, email digests, and in-app alerts, but the team decided to cut email digests from v1 to avoid the deliverability rabbit hole (SPF, DKIM, reputation management). The notification system will ship with in-app alerts and optional browser push notifications only. Target launch is March 28. A soft rollout to beta users will happen on March 25, with three days of monitoring before the public release. The backend will use a simple polling architecture rather than WebSockets to keep infrastructure costs flat.

## Action Items

- [ ] Write the notification preferences UI component [owner:: You] [due:: 2026-03-21]
- [ ] Set up the notifications database table and API endpoints [owner:: Them] [due:: 2026-03-22]
- [ ] Deploy notification service to staging [owner:: Them] [due:: 2026-03-24]
- [ ] Draft the changelog entry for the notification feature [owner:: You] [due:: 2026-03-25]
- [ ] Run load test simulating 500 concurrent users polling for notifications [owner:: Them] [due:: 2026-03-25]
- [ ] Coordinate with beta users for soft rollout [owner:: You] [due:: 2026-03-25]

## Decisions

- Email digests cut from v1, will revisit in v1.1
- Polling architecture instead of WebSockets for notifications
- 30-second polling interval as default, configurable per user
- Soft rollout to beta users on March 25, public launch March 28
- Notifications auto-expire after 30 days

## Transcript

[00:00:00] **You:** Morning. I wanted to nail down the notification system scope before the weekend so we can start building Monday.

[00:00:06] **Them:** Good timing. I was actually sketching out the data model last night. I think we are overcomplicating this.

[00:00:12] **You:** How so?

[00:00:14] **Them:** The original spec has three channels: in-app alerts, browser push, and email digests. The first two are straightforward. Email digests are a completely different beast. We need a transactional email provider, SPF records, DKIM signing, domain reputation management. It is a whole project on its own.

[00:00:32] **You:** Yeah, I had that thought too. The email setup alone could take a week if we hit deliverability issues.

[00:00:38] **Them:** Exactly. And honestly, who reads email digests? Our users live in the app. If we ship in-app alerts and browser push, that covers 95% of the use case.

[00:00:48] **You:** I agree. Let's cut email digests from v1. We can revisit it in v1.1 if users actually ask for it.

[00:00:55] **Them:** Good. Now, for the delivery mechanism. I know WebSockets are the trendy choice, but I think simple polling is better for us right now.

[00:01:04] **You:** Because of infrastructure cost?

[00:01:07] **Them:** Partly. WebSocket connections are persistent. If we have a thousand users online, that is a thousand open connections our server is maintaining. Polling lets us stay on a basic HTTP setup. No special infrastructure, no connection management, no reconnection logic on the client.

[00:01:22] **You:** What polling interval are you thinking?

[00:01:25] **Them:** 30 seconds default. Fast enough that notifications feel responsive, infrequent enough that we are not hammering the server. We can let power users configure it down to 10 seconds if they want.

[00:01:37] **You:** That sounds reasonable. At 30 seconds, even with a few thousand active users, the load is trivial.

[00:01:44] **Them:** Right. And if we ever need real-time, we can swap polling for WebSockets later without changing the notification data model. The upgrade path is clean.

[00:01:53] **You:** Perfect. Let's talk timeline. We said end of March originally. Is that still realistic with the reduced scope?

[00:02:00] **Them:** More than realistic. Without email digests, I think we can have the backend done by the 22nd. That gives us time to test and do a soft rollout.

[00:02:09] **You:** I want to do a soft rollout to our beta users before the public launch. Maybe three days of monitoring.

[00:02:16] **Them:** So beta on the 25th, public on the 28th?

[00:02:19] **You:** Exactly. That gives us the weekend as a buffer too. If something breaks during beta, we have Monday and Tuesday to fix it.

[00:02:27] **Them:** Works for me. One thing I want to decide now: notification expiry. Do they stay forever or auto-delete?

[00:02:34] **You:** Auto-expire. Stale notifications are worse than no notifications. What is a reasonable window?

[00:02:40] **Them:** 30 days. Long enough that people do not miss things on vacation, short enough that the database does not grow forever.

[00:02:48] **You:** 30 days. Done. Let's split the work. I will take the frontend: the notification bell, the preferences panel, the dropdown list. You take the backend: database schema, API endpoints, the polling service.

[00:03:01] **Them:** Agreed. I will have the database table and endpoints ready by the 22nd so you can start integrating the frontend against real data.

[00:03:10] **You:** Good. And I need to write the changelog entry for this feature. I will do that on the 25th once we have the final build.

[00:03:18] **Them:** One more thing. We should run a load test before the public launch. I want to simulate 500 concurrent users polling at 30-second intervals and make sure response times stay under 200ms.

[00:03:30] **You:** Absolutely. Can you set that up as part of the staging deploy?

[00:03:34] **Them:** Yeah. I will deploy to staging on the 24th and run the load test on the 25th, same day as the beta rollout.

[00:03:42] **You:** Great. I will reach out to the beta group today and give them a heads up about the March 25th date.

[00:03:49] **Them:** Sounds good. I think we are in good shape.

[00:03:52] **You:** Agreed. Nice call on cutting the email digests. That would have derailed the whole timeline.

[00:03:58] **Them:** Every feature you do not build is a feature that cannot break.

[00:04:02] **You:** Words to live by. Talk Monday.

[00:04:05] **Them:** See you then.
