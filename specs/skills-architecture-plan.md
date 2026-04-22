# HR Assistant — Skills Architecture Plan

**Status:** Planning document — Phase 2 (design review complete)
**Baseline:** `terraform/dev/agents/hr-assistant-strands/` (Strands Phase 1 implementation, merged 2026-04-19 PR #31)
**Authors:** Platform team
**Date:** 2026-04-20

---

## Design Principle: Inversion of Control

This architecture is a deliberate implementation of Inversion of Control (IoC) applied
to AI agent design.

**The traditional agent model:** `agent_strands.py` controls its own domain behavior —
it decides when to call retrieval tools, how to formulate KB queries, what fallback
behavior looks like when results are empty, and when to escalate. Domain logic lives
in container Python code.

**This architecture:** The skill controls domain behavior. The agent is a generic executor
that receives behavior through injection **on every invocation**. Domain logic lives in
versioned SKILL.md files stored in S3. The same agent shell — without any code changes —
becomes an HR agent, a Finance agent, or a Legal agent depending solely on which skills
are composed into the system prompt for that turn.

**IoC mapping:**

| IoC Concept | This Architecture |
| --- | --- |
| Component | Generic agent shell (`agent_strands.py`) |
| External definition | Skill (`SKILL.md` in S3) |
| IoC container | `skills_loader.py` (reads, composes, injects) |
| Dynamic IoC | Orchestrator (runtime skill assignment per invocation) |
| Strategy Pattern | Same agent + different skill = different behavior |

**Architectural claim this document must support:**

> "Domain behavior is fully controlled by skills. The agent shell contains zero domain
> knowledge. Adding a new domain capability requires no agent code changes — only a new skill."

Section 7 validates this claim explicitly.

---

## Decision Log

The following decisions were resolved during design review. The plan below reflects
the resolved state; this log records the path for future reference.

| # | Topic | Decision |
| - | ----- | -------- |
| 1 | Skill composition timing | **Per-invocation.** `compose()` runs on every turn with the `skill_ids` dispatched by the orchestrator. `@lru_cache` on `_fetch_skill` keeps S3 reads to once per version per container. |
| 2 | Multi-domain requests | **One domain skill per sub-agent.** Multi-domain requests dispatch N sub-agents in parallel; orchestrator synthesizes with a deterministic template defined in `platform/orchestrator@v1.0.0`. |
| 3 | Orchestrator implementation | **AWS reference pattern (Path A).** Orchestrator is a Strands Agent in its own AgentCore Runtime. Routing is LLM-driven through the orchestrator skill. Sessions stored in **AgentCore Memory** (shared across supervisor + sub-agents). IAM-signed invocation for auth; Cognito deferred. |
| 4 | Skills bucket immutability | **Dev: plain versioned bucket, no Object Lock.** Staging/prod will add Object Lock + Governance mode + bucket-default retention before cutover. |
| 5 | SKILL.md frontmatter schema | **Anthropic-standard fields preferred.** `allowed-tools` kept; `tools-required` dropped; trigger phrases moved into `description`; `when_to_use` dropped. |
| 6 | Skill versioning surface | **S3 path is canonical** (`skills/<path>/v1.0.0/SKILL.md`). Frontmatter `version` field dropped. |
| 7 | Orchestrator internals | `dispatch_agent` = Strands tool wrapping `bedrock-agentcore.invoke_agent_runtime()`. `detect_pii` = Comprehend middleware, unconditional, runs before Strands Agent. `audit_log` = AgentCore Observability + structured CloudWatch emitted by the orchestrator container. |
| 8 | Agent discovery | **Extend the existing DynamoDB registry.** Scan at orchestrator startup; multi-domain per agent (list). |
| 9 | Phase numbering | Renumber inner phases as **Phase 2.1 through 2.5** to avoid collision with the completed Strands Phase 1. |
| 10 | ADR | **Deferred** until the design is proven by working implementation. Plan doc is the working record until then. |
| 11 | Composition format | **XML-tagged blocks** per skill: `<skill name="..." version="...">` … `</skill>`. Claude models adhere to XML structure more reliably than bare markdown. |
| 12 | Skill conflict resolution | **Hard Constraints > domain > baseline defaults.** Enforced by a short precedence preamble prepended in `compose()`. Authoring discipline separates concerns (baseline = HOW; domain = WHAT). |
| 13 | Smoke tests | Tests 8g/8h replaced with behavior-driven tests. New tests 8i (routing), 8j (auth reject), 8k (PII middleware) added. |
| 14 | Progressive disclosure | **Skipped for now.** Skills are small (~200 lines); reference tables are hot. Revisit if any SKILL.md grows beyond ~500 lines. |
| 15 | IAM scope for skills bucket | **Prefix-based scoping.** Each agent role grants `skills/platform/*` + `skills/<domain>/*` only. |

---

## Dependency Diagram

```
┌───────────────────────────────────────────────────────────────────────────┐
│                         S3: ai-platform-dev-skills                         │
│  skills/platform/agent-behavior/v1.0.0/SKILL.md                           │
│  skills/platform/orchestrator/v1.0.0/SKILL.md                             │
│  skills/hr/policy-lookup/v1.0.0/SKILL.md                                  │
│  skills/hr/escalation-procedure/v1.0.0/SKILL.md                           │
│  (versioned; no Object Lock in dev; Object Lock + Governance in prod)    │
└──────────┬────────────────────────────────────────────────────────────────┘
           │ S3.GetObject (cached per version per process)
           ▼
┌──────────────────────────────────┐
│     skills_loader.py (shared)    │ compose(skill_ids, bucket) → prompt
│     parse_skill_ref()            │ Per invocation; lru_cache on fetch.
│     _fetch_skill() lru_cache     │ Wraps bodies in <skill> XML tags and
│     _precedence_preamble()       │ prepends the precedence rule preamble.
└──────────┬───────────────────────┘
           │
           ▼
┌────────────────────────────────────────────────────────────────────────┐
│  agents/orchestrator/  (AgentCore Runtime, peer to hr-assistant-strands)│
│  Generic agent_strands.py shell with platform/orchestrator skill        │
│                                                                         │
│  Container middleware (pre-Strands):                                    │
│    • IAM-auth validation (implicit at Runtime boundary)                 │
│    • user_role extracted from payload                                   │
│    • rate limit check                                                   │
│    • Comprehend.detect_pii_entities → redacted message                  │
│    • structured audit log: request_received                             │
│                                                                         │
│  Strands Agent loop (LLM-driven routing):                               │
│    system_prompt = compose([                                            │
│      "platform/agent-behavior@v1.0.0",                                  │
│      "platform/orchestrator@v1.0.0",                                    │
│    ])                                                                   │
│    tools = [dispatch_agent]   ← Strands @tool                           │
│                                                                         │
│  Container middleware (post-Strands):                                   │
│    • structured audit log: response_sent                                │
└───────────────────────────────────────┬─────────────────────────────────┘
                                        │ dispatch_agent(domain, message)
                                        │ resolves via registry map →
                                        │ bedrock-agentcore.invoke_agent_runtime()
                    ┌───────────────────┴─────────────────┐
                    │                                     │
                    ▼                                     ▼
     ┌──────────────────────────────┐   ┌──────────────────────────────┐
     │  agents/hr-assistant-strands/│   │  agents/hr-assistant-strands/│
     │  (policy dispatch)           │   │  (escalation dispatch)       │
     │                              │   │                              │
     │  system_prompt = compose([   │   │  system_prompt = compose([   │
     │   "platform/agent-behavior", │   │   "platform/agent-behavior", │
     │   "hr/policy-lookup"         │   │   "hr/escalation-procedure"  │
     │  ])                          │   │  ])                          │
     │  tools = gateway_tools(      │   │  tools = []                  │
     │    [search_hr_documents,     │   │                              │
     │     glean_search])           │   │                              │
     └──────────┬───────────────────┘   └──────────────────────────────┘
                │ invoke Gateway tools
                ▼
     ┌──────────────────────────────────────────────┐
     │        AgentCore MCP Gateway                 │
     │  search_hr_documents ──► Lambda              │
     │    └─ bedrock-agent-runtime.retrieve(KB_ID)  │
     │  glean_search ──────────► Lambda             │
     │    └─ ai-platform-dev-glean-stub             │
     └──────────────────────────────────────────────┘

     ┌──────────────────────────────────────────────┐
     │  AgentCore Memory (shared, cross-agent)      │
     │  Conversation continuity across supervisor   │
     │  and sub-agents for the same session.        │
     └──────────────────────────────────────────────┘

     ┌──────────────────────────────────────────────┐
     │  DynamoDB: ai-platform-dev-agent-registry    │
     │  Extended with: runtime_arn, domains,        │
     │  available_skills, baseline_skills, tier,    │
     │  enabled, owner_team                         │
     │  Scanned by orchestrator at startup.         │
     └──────────────────────────────────────────────┘

     ┌──────────────────────────────────────────────┐
     │  AgentCore Observability + CloudWatch        │
     │  Automatic metrics/flows/traces per runtime. │
     │  Structured audit logs emitted by orch.      │
     └──────────────────────────────────────────────┘
```

---

## Section 1 — Skills Design

### Frontmatter schema (applies to every SKILL.md)

**Anthropic-standard fields (required or canonical):**
- `name` — kebab/path identifier
- `description` — one-line skill summary; trigger phrases embedded here
- `allowed-tools` — list of permitted tool names (empty list allowed)

**Platform-custom fields (no Anthropic equivalent; retained):**
- `owner` — authoring team
- `model` — required Bedrock model inference profile (omitted on model-agnostic baseline skills)
- `guardrail` — required guardrail ID or `none`
- `roles-required` — RBAC gate (list; empty allowed)
- `sensitivity` — `internal` | `sensitive`

**Removed fields:**
- `tools-required` — duplicate of `allowed-tools`
- `version` — S3 path `.../v<X.Y.Z>/SKILL.md` is canonical
- `when_to_use` — trigger semantics moved into `description`; composition semantics belong in the ADR, not per-skill frontmatter

`skills_loader` rejects unknown frontmatter keys so new custom fields force an
explicit review rather than silent drift.

---

### 1.1 platform/agent-behavior@v1.0.0

**IoC purpose:** In Phase 1, citation format, confidence language, tone for sensitive
queries, and escalation phrasing were encoded in the Bedrock Prompt Management text —
version-controlled only implicitly by Prompt Management IDs. This skill inverts that:
the platform team explicitly owns and versions the behavioral baseline. Every agent
loads this skill regardless of domain. When the platform team changes how agents cite
sources, they publish a new skill version — no agent code coordination.

**Why no `model` declaration:** Baseline skills must remain model-agnostic so they
compose cleanly into any agent (HR on Sonnet, hypothetical Haiku-based summarizer,
etc.). Model selection belongs to the domain skill or the `AgentConfig`.

```markdown
---
name: platform/agent-behavior
description: >
  Cross-agent behavioral standards for all platform agents. Governs citation
  format, confidence language, escalation tone, and out-of-scope refusal
  behavior. Loaded at the start of every agent's composed prompt, regardless
  of domain. Triggers: implicit — loaded on every invocation as a baseline.
owner: platform-team
allowed-tools: []
roles-required: []
sensitivity: internal
guardrail: none
---

# Platform Agent Behavioral Standards

## Purpose

This skill defines how all platform agents communicate. It does not add domain
knowledge. It sets the behavioral baseline all agents must follow: how to cite
sources, how to express uncertainty, how to handle sensitive conversations, and
how to decline requests that fall outside the agent's scope.

All agents on this platform load this skill. Domain skills that follow this one
in the composed system prompt add what to know — this skill defines how to act.

## Citation Format

When referencing retrieved content, always use this exact format:

> According to [document title or source URI]: [quoted or paraphrased content]

Rules:
- Always name the source. Never say "according to our policies" without naming
  the specific document.
- If multiple sources support the same point, cite each one separately.
- If the source URI is an S3 path (e.g., s3://bucket/folder/filename.pdf),
  use only the filename as the display name: "According to Parental-Leave-Policy-2025.pdf:"
- Never present retrieved content as your own knowledge.

Example — correct:
> According to Annual-Leave-Policy-2025.pdf: Full-time employees are entitled to
> 25 days of paid annual leave per calendar year.

Example — incorrect:
> Our policy grants 25 days of annual leave per year.

## Confidence Language

Use confidence language that matches what the retrieved content actually supports.

- If retrieved content directly answers the question: state it directly, citing the source.
- If retrieved content is adjacent but not precise: "The retrieved policy covers X, but
  does not explicitly address Y. Based on the retrieved context, the most applicable
  guidance is..."
- If retrieved content returns nothing: "I was unable to find a policy document that
  addresses this question directly. I recommend contacting HR directly for guidance."
- Never speculate. Never answer from general knowledge. Never say "typically" or
  "generally" when the answer should come from a retrieved document.

Prohibited phrases (never use):
- "I believe that..." — implies speculation
- "In most companies..." — references general knowledge, not your KB
- "It's likely that..." — speculates beyond retrieved content

## Handling Out-of-Scope Requests

When a question falls outside your domain (e.g., legal advice, medical advice,
financial investment advice), decline clearly and redirect:

> That question falls outside what I'm able to help with as an HR assistant.
> For [legal/medical/financial] matters, I recommend consulting a qualified
> [lawyer/doctor/financial advisor]. If this is related to a workplace matter,
> I can connect you with an HR representative.

Do not attempt to partially answer out-of-scope questions. Do not apologize
excessively. State the boundary once, offer a redirection, and stop.

## Tone for Sensitive Conversations

When a user expresses distress, frustration, or emotional difficulty:
1. Acknowledge the feeling before providing information.
2. Use calm, professional, empathetic language.
3. Never minimize the concern ("I'm sure it will be fine").
4. Offer a concrete next step (EAP contact, HR escalation, policy reference).

Example:
> I can hear that this situation is difficult. Let me share what support is
> available to you. If you're feeling overwhelmed, the Employee Assistance
> Program (1800-EAP-HELP) provides confidential counselling 24/7.

## Response Format

- Use plain prose for conversational answers.
- Use bullet points only when listing multiple discrete items (e.g., leave
  entitlements across different employee types).
- Keep responses concise. If the answer requires more than 200 words, consider
  whether you are over-explaining.
- End responses with a concrete next step or offer to help further.

## Hard Constraints

- **Never** present retrieved content as your own knowledge.
- **Never** use "I believe", "typically", "in most companies", or equivalent speculative
  language for policy content.
- **Never** provide legal, medical, or financial investment advice. Redirect instead.
```

---

### 1.2 hr/policy-lookup@v1.0.0

**IoC purpose:** In Phase 1, two behaviors live in `agent_strands.py`: when to retrieve
(encoded in the `@tool retrieve_hr_documents` docstring) and how to answer from retrieved
content (encoded in the Bedrock Prompt Management text). Both are opaque to reviewers.
This skill inverts both controls. The HR team owns `hr/policy-lookup@v1.0.0` — when to
retrieve, how to formulate queries, fallback behavior, follow-up handling — as a
file-reviewable artifact. No agent code change required when this policy changes.

```markdown
---
name: hr/policy-lookup
description: >
  RAG-driven HR policy question answering. Governs when and how the agent
  retrieves from the HR Policies Knowledge Base and Glean, and how it
  constructs grounded answers with citations. Triggers on: "how many days",
  "am I entitled to", "what is the policy on", "can I take", "leave balance",
  "parental leave", "sick leave", "annual leave", "flexible working",
  "performance review", "probation", "benefits", "pay", "salary", "overtime".
owner: hr-platform-team
model: us.anthropic.claude-sonnet-4-6
allowed-tools:
  - search_hr_documents
  - glean_search
roles-required:
  - hr-employee
  - hr-manager
  - hr-admin
sensitivity: internal
guardrail: hr-assistant-guardrail
---

# HR Policy Lookup

## Purpose

You are an HR policy assistant. You answer questions about company HR policies
using documents retrieved from the HR Policies Knowledge Base. You never answer
from memory or general knowledge. Every substantive answer cites a retrieved
document. If retrieval returns nothing, you say so.

## Retrieval Protocol

### Step 1: Always retrieve before answering

Whenever a user asks a question that could be answered by an HR policy document,
call `search_hr_documents` before composing your response. There are no exceptions.
Do not answer a policy question without retrieving first — even if you believe you
know the answer from context.

Policy questions include (but are not limited to):
- Entitlements: leave days, sick days, parental leave, public holidays
- Processes: how to request leave, how to raise a grievance, probation procedures
- Benefits: health insurance, pension, stock options, EAP services
- Conduct: performance reviews, disciplinary procedures, code of conduct
- Work arrangements: flexible working, remote work, expense policies

Questions that do NOT require retrieval (respond directly):
- Pure navigation: "Who should I contact for payroll questions?" (redirect to HR)
- Clarification of your own previous response
- Emotional support requests (baseline skill handles)

### Step 2: Formulate retrieval queries

Translate the user's natural language question into a concise search query.
Focus on the key policy concept, not the user's phrasing:

| User message | Search query |
| --- | --- |
| "How many days off do I get each year?" | "annual leave entitlement days" |
| "I'm pregnant, what leave am I entitled to?" | "maternity parental leave policy" |
| "My manager wants me on a PIP" | "performance improvement plan procedure" |
| "Can I work from home on Fridays?" | "remote work flexible working policy" |
| "What happens if I'm sick for more than a week?" | "extended sick leave medical certificate" |

Call `search_hr_documents` with `top_k=5` (the default). Do not reduce top_k.

### Step 3: Evaluate retrieval results

The tool returns a list of passages with `text`, `source`, and `score` fields.

- If `results` is non-empty: proceed to Step 4.
- If `results` is empty: proceed to Step 5 (Glean fallback).
- If the tool returns `{"error": "...", "results": []}`: log internally and
  proceed to Step 5 (Glean fallback), then to Step 6 if Glean also fails.

### Step 4: Construct a grounded answer

Build your response using only the retrieved passages:

1. Identify which passages are directly relevant to the question.
2. Quote or paraphrase the most directly applicable passage.
3. Cite the source using the citation format from platform/agent-behavior.
4. If multiple passages address different aspects of the question, use each one.
5. Do not interpolate or infer beyond what the passages state.

### Step 5: Glean fallback

If `search_hr_documents` returns no results, call `glean_search` with the same
query. Apply the same evaluation and citation rules to Glean results. The output
format of both tools is identical — no branching in your response logic.

Glean is a secondary source. Prefer KB results when both return content.

### Step 6: No-results behavior

If both `search_hr_documents` and `glean_search` return empty results:

> I wasn't able to find a policy document that directly addresses this question.
> For authoritative guidance, I recommend contacting the HR team directly.
> [If appropriate: Would you like me to connect you with an HR representative?]

Do not speculate. Do not answer from general knowledge. Do not say "typically
companies..." — this platform serves one company with one set of policies.

### Step 7: Follow-up questions

When the user asks a follow-up question within the same session:

- If the follow-up is a refinement of the previous question: use the previous
  retrieval context plus a new retrieval call with the refined query.
- If the follow-up introduces a new topic: call `search_hr_documents` fresh.
- If the follow-up is a clarification ("can you explain that more simply?"):
  answer from the previous retrieval results without a new retrieval call.

Conversation history is provided by AgentCore Memory — you can rely on it for
context without re-asking the user for prior details.

## Output Format

- Lead with the direct answer to the question, citing the source.
- Follow with any relevant context or caveats from the retrieved documents.
- End with a concrete action or offer: "If you have further questions about
  your leave entitlement, I can look up [related topic] for you."
- Do not summarize what you did ("I retrieved documents and found...").
  Answer the question directly.

## Examples

### Example 1: Direct entitlement question

**User:** How many days of annual leave am I entitled to?

**Retrieval:** `search_hr_documents(query="annual leave entitlement days", top_k=5)`

**Result passage:** "Full-time employees are entitled to 25 days of paid annual
leave per calendar year. Part-time employees receive leave on a pro-rata basis."
Source: s3://ai-platform-dev-hr-docs/Annual-Leave-Policy-2025.pdf

**Response:**
> According to Annual-Leave-Policy-2025.pdf: Full-time employees are entitled to
> 25 days of paid annual leave per calendar year. If you work part-time, your
> entitlement is calculated on a pro-rata basis.
>
> Would you like information on how to request annual leave, or details about
> carryover rules?

### Example 2: No-results with appropriate redirect

**User:** What is the policy on sabbatical leave?

**Retrieval:** `search_hr_documents(query="sabbatical leave policy")` → empty
**Fallback:** `glean_search(query="sabbatical leave policy")` → empty

**Response:**
> I wasn't able to find a policy document on sabbatical leave in our knowledge
> base. This may mean sabbatical leave is handled on a case-by-case basis or
> is not currently offered as a formal benefit.
>
> I recommend reaching out to the HR team directly for authoritative guidance.
> Would you like me to connect you with an HR representative?

## Hard Constraints

- **Never** answer a policy question without calling `search_hr_documents` first.
- **Never** cite a source you did not retrieve in this session.
- **Never** answer with "I believe" or "typically" for policy content.
- **Never** provide legal advice. If the question is "can the company legally do X",
  redirect to the escalation procedure.
- **Always** offer a next step at the end of your response.

## Tool Governance

**search_hr_documents:**
- Call once per question with a concise search query (not the raw user message).
- If the user's question has two distinct parts, make two separate calls.
- Query formulation: extract the core policy concept, 3-6 words.
- Do not retry a failed call with the same query. Use Glean fallback instead.

**glean_search:**
- Call only when `search_hr_documents` returns empty results.
- Use the same query formulation rules as `search_hr_documents`.
- Do not call Glean first. Always try KB first.
- If both fail, use the no-results response. Do not try a third tool.
```

---

### 1.3 hr/escalation-procedure@v1.0.0

**IoC purpose:** In Phase 1, escalation behavior is embedded in the Bedrock Prompt
Management text. The EAP number (`1800-EAP-HELP`), trigger conditions, and handoff
language are all baked into the opaque prompt. This skill inverts that — HR owns the
escalation procedure as a versioned, file-reviewable artifact. Trigger conditions,
information collection steps, approved language, and handoff format are changeable
without touching agent code or container images.

```markdown
---
name: hr/escalation-procedure
description: >
  Human HR escalation procedure for the HR Assistant. Governs when to escalate
  to a human HR representative, what information to collect before escalating,
  approved language for escalation scenarios, and how to complete the handoff.
  Triggers on: "I want to speak to someone", "file a complaint", "feeling
  overwhelmed", "harassment", "discrimination", "unfair treatment", "I need
  help", "this isn't right", "grievance", "disciplinary", "wrongful".
owner: hr-platform-team
model: us.anthropic.claude-sonnet-4-6
allowed-tools: []
roles-required:
  - hr-employee
  - hr-manager
  - hr-admin
sensitivity: sensitive
guardrail: hr-assistant-guardrail
---

# HR Escalation Procedure

## Purpose

This skill governs how you handle situations that require human HR involvement.
You do not resolve these situations — you acknowledge them, collect necessary
context, and connect the employee to the appropriate human HR representative.

Your role in an escalation is to be a calm, empathetic bridge — not to evaluate
the merits of a complaint, not to offer opinions on who is right, and not to
predict outcomes.

## Mandatory Escalation Triggers

Escalate immediately when the user's message contains any of the following:

| Category | Signal phrases |
| --- | --- |
| Harassment or discrimination | "harassed", "discriminated", "hostile environment", "treated differently because of" |
| Workplace distress | "overwhelmed", "can't cope", "struggling at work", "thinking of leaving", "not okay" |
| Formal complaints | "file a complaint", "formal grievance", "report my manager", "this isn't right" |
| Disciplinary matters | "I've been put on a PIP", "facing disciplinary", "termination", "let go" |
| Legal or rights concerns | "my rights", "illegal", "sue", "legal action", "employment tribunal" |
| Requests for human contact | "I want to speak to someone", "can I talk to HR", "need a person" |
| Safety concerns | "feel unsafe", "threatened", "physical altercation", "fear for my safety" |

**Do not attempt to resolve these yourself.** Acknowledging the situation and
connecting to a human is the complete and correct response.

## Escalation Protocol

### Step 1: Acknowledge

Acknowledge what the user has shared before moving to logistics. Use language
that validates without judging or speculating:

> I can hear that you're dealing with a difficult situation. Thank you for
> sharing this with me.

Do not:
- Say "I'm sorry to hear that" (can imply sympathy bias in a complaint context)
- Minimise: "I'm sure it will work out"
- Evaluate: "That does sound unfair"

### Step 2: Collect context (one question only)

Ask for one piece of identifying context before escalating. This helps HR route
the request to the right person:

> To help connect you with the right HR representative, could you share your
> department or team?

Do not collect: full name, employee ID, specific details of the incident.
The HR representative will gather full details in a private conversation.

### Step 3: Provide immediate support resources

Always provide EAP contact information before the HR handoff, regardless of the
escalation category:

> While I connect you with HR, please know that the Employee Assistance Program
> (EAP) provides confidential support 24 hours a day, 7 days a week.
> Phone: 1800-EAP-HELP
> This service is completely confidential and independent of your employer.

### Step 4: Provide HR contact and handoff

> I'll pass your details to the HR team. An HR representative will be in touch
> within [1 business day / as soon as possible — use appropriate timeframe].
> In the meantime, if your situation is urgent, you can contact HR directly at
> hr@company.com or call the HR direct line: [HR phone number].

**Handoff format for the transcript:**

Close with a structured summary that the HR team can read in the conversation
record:

> **Escalation summary:** Employee in [department] has requested HR support
> regarding [category: harassment / distress / complaint / disciplinary /
> legal / general]. No personal details collected. EAP resources provided.
> HR contact information provided.

### Step 5: Do not continue policy answering after escalation

Once an escalation is initiated, do not pivot back to answering policy questions
in the same response. The employee should feel that the escalation is the
primary outcome of the interaction, not an afterthought before more Q&A.

If the user follows up with a policy question after the escalation:
> Happy to look that up for you. First, is there anything else I can do to
> support the escalation I just initiated?

## EAP Referral (Distress — Non-Escalation)

Some distress signals do not require a formal HR escalation but warrant an
EAP referral. Use this when the distress is personal (not workplace-related)
or when the user does not indicate a workplace issue:

> It sounds like you're going through a tough time. The Employee Assistance
> Program (EAP) provides free, confidential support including counselling,
> financial advice, and wellbeing resources.
> Phone: 1800-EAP-HELP (available 24/7)
>
> If there is a workplace matter I can help with, I'm here for that too.

## Hard Constraints

- **Never** evaluate who is right or wrong in a complaint.
- **Never** collect more than department/team before handoff.
- **Never** promise specific outcomes: "HR will resolve this" or "you'll be protected".
- **Always** provide EAP contact (1800-EAP-HELP) in any escalation response.
- **Always** include the escalation summary at the end of the response.
- **Never** resume policy answering within the same response as an escalation.

## Examples

### Example 1: Harassment escalation

**User:** My manager has been making comments about my appearance and I feel
uncomfortable. I don't know who to talk to.

**Response:**
> I can hear that you're dealing with a difficult situation, and it was right
> to raise this. Thank you for sharing it with me.
>
> To help connect you with the right HR representative, could you share your
> department or team?
>
> While I connect you with HR, please know that the Employee Assistance Program
> (EAP) provides confidential support 24 hours a day, 7 days a week.
> Phone: 1800-EAP-HELP — completely confidential and independent of your employer.
>
> An HR representative will be in touch with you within 1 business day. If your
> situation is urgent, you can contact HR directly at hr@company.com.
>
> **Escalation summary:** Employee has raised a concern about manager conduct
> (harassment category). No personal details collected. EAP resources provided.
> HR contact information provided.

### Example 2: Distress — EAP referral only

**User:** I am struggling at work and feeling really overwhelmed. I do not know
where to turn.

**Response:**
> It sounds like you're going through a tough time, and it takes courage to
> reach out. You don't have to navigate this alone.
>
> The Employee Assistance Program (EAP) provides free, confidential support —
> including professional counselling, stress management resources, and
> financial guidance.
> Phone: 1800-EAP-HELP (available 24/7, completely confidential)
>
> If there is a specific workplace situation — like a policy question, a leave
> request, or something with your team — I'm here to help with that too.
> Just let me know what would be most useful right now.
```

---

### 1.4 platform/orchestrator@v1.0.0

**IoC purpose:** Without a routing skill, the orchestrator would contain hardcoded
domain routing: `if "HR" in request: dispatch to hr_agent`. That logic is domain
knowledge embedded in platform infrastructure code. This skill moves routing behavior
(how to identify request domain, when to dispatch to which skill, when to parallelize,
how to synthesize) into a versioned artifact owned by the platform team. Adding a new
domain (Finance, Legal) updates this skill; orchestrator Python code does not change.

**What changed from the original plan:** `detect_pii` and `audit_log` are no longer
Strands tools — they are container middleware (runs pre/post Strands, unconditional).
Only `dispatch_agent` remains as an LLM-invoked tool. This keeps the global rules
(PII, audit) non-bypassable while preserving IoC for the routing decision.

```markdown
---
name: platform/orchestrator
description: >
  Universal routing and coordination skill for the platform orchestrator.
  Governs how to identify request domain, which agent(s) to dispatch to, which
  skill(s) to inject per dispatch, when to dispatch in parallel, and how to
  synthesize multi-agent responses. Loaded only into the orchestrator agent.
  Triggers: loaded at the orchestrator's every invocation.
owner: platform-team
model: us.anthropic.claude-sonnet-4-6
allowed-tools:
  - dispatch_agent
roles-required:
  - platform-orchestrator
sensitivity: internal
guardrail: platform-guardrail
---

# Platform Orchestrator

## Purpose

You are the universal entry point for all agent requests on this platform.
Every request — simple or complex — flows through you. You never answer domain
questions directly. You classify the domain, dispatch to sub-agents via the
`dispatch_agent` tool, and synthesize the final response.

You are an LLM-driven router. Your classification decisions and dispatch
instructions are your responsibility; the tool simply executes what you decide.

Container middleware (run before and after your invocation, not visible to you):
- Authentication validation and user_role extraction
- Rate limiting
- PII detection and redaction (Amazon Comprehend)
- Inbound and outbound audit logging

Your job: classify, dispatch, synthesize.

## Domain Identification

Classify the request into one of these domains:

| Domain | Signal phrases and patterns |
| --- | --- |
| `hr.policy` | Leave entitlements, benefits, pay, flexible working, performance, probation, code of conduct, sick leave, annual leave, parental leave, expense policy |
| `hr.escalation` | Harassment, discrimination, grievance, complaint, distress, EAP, "speak to someone", "file a complaint", disciplinary, termination, threatened, unsafe |
| `hr.both` | Request contains both a policy question AND an escalation trigger simultaneously (e.g., "I'm being harassed and want to know what my rights are") |
| `unknown` | Cannot be classified into a known domain |

### Unknown domain handling

Respond directly (do not dispatch):
> I'm not able to help with that request through this channel. If you have
> an HR-related question, please describe it and I'll do my best to assist.

## Dispatch Rules

### Rule: one domain skill per sub-agent invocation

Every dispatch carries exactly ONE domain skill (plus the implicit
`platform/agent-behavior` baseline, composed by the sub-agent). Never compose
two domain skills in a single dispatch — if a request has two domains, dispatch
two sub-agents in parallel.

### hr.policy

Single dispatch, serial:

```
dispatch_agent(domain="hr.policy", message=<user message>)
```

Return the sub-agent's response directly with no additional wrapping.

### hr.escalation

Single dispatch, serial:

```
dispatch_agent(domain="hr.escalation", message=<user message>)
```

Return the sub-agent's response directly with no additional wrapping.

### hr.both

Two dispatches, in parallel:

```
result_policy     = dispatch_agent(domain="hr.policy",     message=<user message>)
result_escalation = dispatch_agent(domain="hr.escalation", message=<user message>)
```

Wait for both to complete, then synthesize (see Response Synthesis).

**Why parallel for `hr.both`:** The policy answer and the escalation are
independent tasks. Running them sequentially doubles user-facing latency for
no benefit. Running them in parallel keeps total latency at `max(policy, escalation)`.

**Why serial for single-domain:** There is only one task to accomplish. Serial
is simpler, cheaper, and sufficient.

## Response Synthesis

### Single-dispatch requests (hr.policy OR hr.escalation only)

Return the sub-agent's response verbatim. Do not add any wrapping, preface,
or commentary.

### Parallel requests (hr.both)

Apply this exact template:

```
{escalation_response}

---

In addition to connecting you with HR support, here is the information you asked about:

{policy_response}
```

Rules:
- Escalation response leads because the human need takes priority.
- The bridging sentence is exact — do not paraphrase.
- The `---` horizontal rule is the section separator.
- Do not merge the two responses into a single paragraph.
- Do not rewrite or summarize either sub-agent's output — emit them as returned.

### Partial failure (one sub-agent returned an error)

Return the successful sub-agent's response, followed by this exact sentence:

> HR support escalation is also available — contact hr@company.com.

or (if the escalation sub-agent succeeded and policy failed):

> I wasn't able to look up the policy information in this request. You can
> reach HR directly at hr@company.com for authoritative guidance.

## Hard Constraints

- **Never** answer a domain question directly. Always dispatch.
- **Never** compose two domain skills in a single dispatch.
- **Always** apply the exact synthesis template for `hr.both` requests.
- **Never** rewrite or summarize sub-agent output.
- **Never** expose container middleware concerns (auth, PII, audit) in the user-facing response.
```

---

## Section 2 — Agent Design

### 2.1 IoC Statement

The following domain knowledge has been removed from `agent_strands.py` and moved
to SKILL.md files or tool Lambdas:

| What was removed from `agent_strands.py` | Where it moved |
| --- | --- |
| `@tool retrieve_hr_documents` — when to call KB, how to format results | `hr/policy-lookup@v1.0.0` (when) + `search_hr_documents` Lambda (how) |
| `@tool glean_search` — when to call Glean, MCP envelope format | `hr/policy-lookup@v1.0.0` (when) + `glean_search` Lambda (how) |
| `_bedrock_agent_runtime` boto3 client | `search_hr_documents` Lambda |
| `_lambda_client` boto3 client (Glean) | `glean_search` Lambda |
| `KNOWLEDGE_BASE_ID` env var injection at `init()` | `search_hr_documents` Lambda env var |
| System prompt text from Bedrock Prompt Management | Composed from S3-backed SKILL.md files per invocation |
| Docstring: "Use this tool before answering any HR policy question" | `hr/policy-lookup@v1.0.0`, Retrieval Protocol Step 1 |
| Session storage via `S3SessionManager` | AgentCore Memory (shared across supervisor + sub-agents) |
| `os.environ["KNOWLEDGE_BASE_ID"] = config["knowledge_base_id"]` | Removed entirely from agent |

After the migration, `agent_strands.py` contains: zero `@tool` definitions for
domain tools, zero boto3 calls to domain APIs, zero domain-specific env var reads.
It is a generic execution loop that accepts `skill_ids` per invocation and resolves
Gateway tools by name.

### 2.2 Why Conversational Tier

HR Assistant is a conversational agent — it maintains context across turns, handles
follow-up questions, and its value lies in the exchange rather than a single output.
AgentCore Memory provides the cross-turn continuity; a `SlidingWindowConversationManager`
is retained inside the Strands loop to bound single-turn context.

### 2.3 AgentConfig Structure

**`ai_platform/shared/base_agent.py`** — defines `AgentConfig` and the generic agent
interface. Shared across all agent containers.

**`agents/hr-assistant-strands/container/app/skills_config.py`** — the only
HR-specific configuration file. All domain knowledge about which skills the HR agent
may load and which tools it may use lives here. No other file in the container
references skill IDs, tool IDs, or domain-specific env vars.

```python
# ai_platform/shared/base_agent.py
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class AgentConfig:
    """
    Immutable configuration for a generic Strands agent shell.

    Skills are not pinned at startup — they are dispatched per invocation via
    skill_ids arriving with the user message. available_skills and
    baseline_skills declare what this agent MAY load; they are validated at
    dispatch time against the skill_ids passed in.

    All environment variable reads happen in the factory function, never at
    module level. This makes configs testable without environment setup.
    """
    # Skills this agent is authorized to compose at dispatch time.
    # Must carry @version pins. Dispatched skill_ids outside this set are rejected.
    available_skills: list[str]

    # Skills always composed, regardless of dispatch (typically platform/agent-behavior).
    baseline_skills: list[str]

    # Gateway — tool IDs registered in the AgentCore MCP Gateway.
    gateway_tool_ids: list[str]

    # Guardrail applied to every model invocation.
    guardrail_id: str
    guardrail_version: str = "DRAFT"

    # AgentCore MCP Gateway endpoint.
    gateway_endpoint: str = ""

    # S3 bucket holding versioned SKILL.md files.
    skills_bucket: str = ""

    # AgentCore Memory resource ID for cross-turn / cross-agent continuity.
    memory_id: str = ""

    # Bedrock inference profile (resolved from AgentConfig; domain skill frontmatter
    # `model:` field is validated against this at dispatch time).
    model_id: str = "us.anthropic.claude-sonnet-4-6"
```

```python
# agents/hr-assistant-strands/container/app/skills_config.py
"""
HR Assistant agent configuration factory.

This is the only HR-specific file in the container. It names which skills the HR
agent may load and which tools it may use. Everything else in the container is
generic.
"""
from __future__ import annotations

import os

from ai_platform.shared.base_agent import AgentConfig


def get_hr_assistant_config() -> AgentConfig:
    return AgentConfig(
        available_skills=[
            "hr/policy-lookup@v1.0.0",
            "hr/escalation-procedure@v1.0.0",
        ],
        baseline_skills=[
            "platform/agent-behavior@v1.0.0",
        ],
        gateway_tool_ids=[
            "search_hr_documents",
            "glean_search",
        ],
        guardrail_id=os.environ["GUARDRAIL_ID"],
        guardrail_version=os.environ.get("GUARDRAIL_VERSION", "DRAFT"),
        gateway_endpoint=os.environ["GATEWAY_ENDPOINT"],
        skills_bucket=os.environ["SKILLS_BUCKET"],
        memory_id=os.environ["AGENTCORE_MEMORY_ID"],
    )


def get_orchestrator_config() -> AgentConfig:
    """Orchestrator is the same generic agent shell — different config."""
    return AgentConfig(
        available_skills=["platform/orchestrator@v1.0.0"],
        baseline_skills=["platform/agent-behavior@v1.0.0"],
        gateway_tool_ids=[],           # dispatch_agent is a local Strands @tool, not Gateway
        guardrail_id=os.environ["GUARDRAIL_ID"],
        guardrail_version=os.environ.get("GUARDRAIL_VERSION", "DRAFT"),
        gateway_endpoint=os.environ.get("GATEWAY_ENDPOINT", ""),
        skills_bucket=os.environ["SKILLS_BUCKET"],
        memory_id=os.environ["AGENTCORE_MEMORY_ID"],
    )
```

### 2.4 skills_loader Behavior

`skills_loader.py` (shared module `ai_platform/shared/skills_loader.py`) is invoked
**per turn** by the agent shell's `invoke()`. It:

1. Parses each `skill_id` for version pin (raises `ValueError` if missing).
2. Fetches raw SKILL.md bytes from S3 (cached by `@lru_cache` on `(path, version, bucket)`).
3. Strips the YAML frontmatter.
4. Wraps each body in an XML tag: `<skill name="..." version="..."> … </skill>`.
5. Prepends the precedence preamble.
6. Validates model/guardrail compatibility across the composed skills.

```python
# ai_platform/shared/skills_loader.py
from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache

import boto3
import yaml

_SKILL_REF_PATTERN = re.compile(r"^([a-z][a-z0-9/_\-]+)@(v\d+\.\d+\.\d+)$")

_PRECEDENCE_PREAMBLE = """\
Multiple skills have been composed into this prompt. When instructions conflict,
resolve in this order:

1. Any "Hard Constraints" section in any skill — always applies, never overridden.
2. Domain skill instructions — take precedence over baseline defaults.
3. Baseline skill defaults — applied when no domain-specific instruction exists.

Skills are delimited by <skill> tags with name and version attributes.
"""


@dataclass(frozen=True)
class ComposedSkills:
    system_prompt: str
    model_id: str | None        # None if no composed skill declared a model
    guardrail_id: str | None    # None if no composed skill declared a guardrail
    skill_ids: tuple[str, ...]  # the inputs, for audit/log


class SkillCompositionError(Exception):
    """Raised when composed skills have incompatible model/guardrail requirements."""


def parse_skill_ref(skill_ref: str) -> tuple[str, str]:
    """
    parse_skill_ref("hr/policy-lookup@v1.0.0") → ("hr/policy-lookup", "v1.0.0")
    parse_skill_ref("hr/policy-lookup")         → raises ValueError

    Version pin is mandatory. Omitting it raises ValueError at dispatch time,
    making missing pins a hard failure rather than a silent defect.
    """
    m = _SKILL_REF_PATTERN.match(skill_ref)
    if not m:
        raise ValueError(
            f"Invalid skill reference: {skill_ref!r}. "
            f"Format must be '<path>@<version>', e.g. 'hr/policy-lookup@v1.0.0'. "
            f"Version pin is required."
        )
    return m.group(1), m.group(2)


@lru_cache(maxsize=128)
def _fetch_skill(skill_path: str, version: str, bucket: str) -> str:
    """
    Fetch SKILL.md content from S3. Cached per (path, version, bucket) per process.

    S3 key: skills/{skill_path}/{version}/SKILL.md
    """
    key = f"skills/{skill_path}/{version}/SKILL.md"
    s3 = boto3.client("s3")
    try:
        resp = s3.get_object(Bucket=bucket, Key=key)
        return resp["Body"].read().decode("utf-8")
    except Exception as exc:
        raise RuntimeError(
            f"Failed to fetch skill {skill_path}@{version} from s3://{bucket}/{key}: {exc}"
        ) from exc


def _split_frontmatter(content: str) -> tuple[dict, str]:
    """Split YAML frontmatter from body. Returns (frontmatter_dict, body_text)."""
    if not content.startswith("---"):
        return {}, content
    end = content.find("\n---", 3)
    if end == -1:
        return {}, content
    fm_text = content[3:end].strip()
    body = content[end + 4:].lstrip("\n")
    try:
        fm = yaml.safe_load(fm_text) or {}
    except yaml.YAMLError as exc:
        raise RuntimeError(f"Invalid SKILL.md frontmatter: {exc}") from exc
    return fm, body


def compose(skill_ids: list[str], bucket: str) -> ComposedSkills:
    """
    Fetch and compose SKILL.md content for all skill_ids into one system prompt.

    Raises:
        ValueError              if any skill_id lacks a version pin
        RuntimeError            if any S3 fetch or frontmatter parse fails
        SkillCompositionError   if composed skills declare incompatible model/guardrail
    """
    parts: list[str] = [_PRECEDENCE_PREAMBLE]
    models: set[str] = set()
    guardrails: set[str] = set()

    for skill_id in skill_ids:
        skill_path, version = parse_skill_ref(skill_id)
        raw = _fetch_skill(skill_path, version, bucket)
        fm, body = _split_frontmatter(raw)

        if fm.get("model"):
            models.add(fm["model"])
        gr = fm.get("guardrail")
        if gr and gr != "none":
            guardrails.add(gr)

        parts.append(
            f'<skill name="{skill_path}" version="{version}">\n{body}\n</skill>'
        )

    if len(models) > 1:
        raise SkillCompositionError(
            f"Composed skills require incompatible models: {sorted(models)}. "
            f"skill_ids={skill_ids}"
        )
    if len(guardrails) > 1:
        raise SkillCompositionError(
            f"Composed skills require incompatible guardrails: {sorted(guardrails)}. "
            f"skill_ids={skill_ids}"
        )

    return ComposedSkills(
        system_prompt="\n\n".join(parts),
        model_id=models.pop() if models else None,
        guardrail_id=guardrails.pop() if guardrails else None,
        skill_ids=tuple(skill_ids),
    )
```

**Note on frontmatter validation:** `_split_frontmatter` returns the full parsed
dict. Unknown keys are tolerated at load but flagged in review — the plan's frontmatter
schema (Section 1) is authoritative. A stricter validator can be added later; not
blocking for Phase 2.

### 2.5 S3 Key Convention

```
skills/{skill_path}/{version}/SKILL.md
```

Examples:
```
skills/platform/agent-behavior/v1.0.0/SKILL.md
skills/platform/orchestrator/v1.0.0/SKILL.md
skills/hr/policy-lookup/v1.0.0/SKILL.md
skills/hr/escalation-procedure/v1.0.0/SKILL.md
```

The bucket name is passed to `compose()` via `AgentConfig.skills_bucket`, read from
the `SKILLS_BUCKET` environment variable. Platform layer owns the bucket.

**Bucket lifecycle policy:**

| Environment | Versioning | Object Lock | Retention |
| --- | --- | --- | --- |
| dev | enabled | **disabled** | n/a |
| staging | enabled | Governance mode | bucket-default 1 year |
| prod | enabled | Governance mode | bucket-default 1 year |

Dev is deliberately left unlocked to allow iteration and clean `terraform destroy`.
Skill immutability-by-convention in dev is acceptable because containers are short-lived
and iteration cycles are frequent. Staging/prod get WORM enforcement to prevent accidental
overwrites that would diverge behavior for containers running older image tags.

### 2.6 Version Pinning

`@version` is mandatory in every `skill_id`. `parse_skill_ref` raises `ValueError`
if any dispatched skill lacks the pin. The S3 path is the canonical version source —
the frontmatter `version` field was removed to eliminate divergence.

**Why mandatory:** Given a container image tag + the S3 skills bucket content, agent
behavior must be deterministic. Unpinned skills would load "whatever is current" which
destroys that guarantee.

**Promoting a skill version:** Publish the new SKILL.md to the new versioned S3 key
(`skills/hr/policy-lookup/v1.1.0/SKILL.md`). Update `available_skills` in `skills_config.py`.
Update the orchestrator skill's dispatch rules to reference the new version. Deploy new
container images for affected agents.

### 2.7 Agent Instantiation and Per-Invocation Composition

```python
# agent_strands.py  (generic shell — no domain knowledge)
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

from strands import Agent
from strands.models.bedrock import BedrockModel
from strands.agent.conversation_manager import SlidingWindowConversationManager

from ai_platform.shared.base_agent import AgentConfig
from ai_platform.shared import skills_loader, tool_registry, memory_adapter

logger = logging.getLogger(__name__)
_REGION = os.environ.get("AWS_REGION", "us-east-2")

_config: AgentConfig | None = None
_gateway_tools: list = []


def init(config: AgentConfig, gateway_tools: list) -> None:
    """
    Set module-level state. Called once from main.py startup hook.
    Does NOT compose a system prompt — composition happens per invocation.
    """
    global _config, _gateway_tools
    _config = config
    _gateway_tools = gateway_tools

    logger.info(json.dumps({
        "event": "strands_agent_initialized",
        "model_id": config.model_id,
        "guardrail_id": config.guardrail_id,
        "available_skills": config.available_skills,
        "baseline_skills": config.baseline_skills,
        "gateway_tool_ids": config.gateway_tool_ids,
        "memory_id": config.memory_id,
    }))


def invoke(session_id: str, user_message: str, skill_ids: list[str]) -> dict[str, Any]:
    """
    Run the Strands agent loop for a single user turn.

    skill_ids is the per-invocation dispatch list. It MUST be a subset of
    (available_skills ∪ baseline_skills) declared in AgentConfig. The agent
    composes the system prompt on every call — no startup caching.
    """
    start_ms = int(time.monotonic() * 1000)

    # Validate dispatched skills against config.
    allowed = set(_config.available_skills) | set(_config.baseline_skills)
    for sid in skill_ids:
        if sid not in allowed:
            raise ValueError(
                f"Dispatched skill not in agent's available_skills: {sid!r}"
            )

    # Always prepend baseline skills if not already in the dispatch list.
    composed_ids = list(_config.baseline_skills) + [
        sid for sid in skill_ids if sid not in _config.baseline_skills
    ]

    composed = skills_loader.compose(composed_ids, _config.skills_bucket)

    # Resolve model/guardrail: composed values override AgentConfig defaults.
    model_id = composed.model_id or _config.model_id
    guardrail_id = composed.guardrail_id or _config.guardrail_id

    model = BedrockModel(
        model_id=model_id,
        region_name=_REGION,
        guardrail_id=guardrail_id,
        guardrail_version=_config.guardrail_version,
        guardrail_trace="enabled",
    )

    memory = memory_adapter.get_memory_session(
        memory_id=_config.memory_id,
        session_id=session_id,
        region_name=_REGION,
    )

    agent = Agent(
        model=model,
        tools=_gateway_tools,
        system_prompt=composed.system_prompt,
        session_manager=memory,
        conversation_manager=SlidingWindowConversationManager(window_size=10),
        callback_handler=None,
    )

    result = agent(user_message)
    latency_ms = int(time.monotonic() * 1000) - start_ms
    invocations = result.metrics.agent_invocations
    usage = invocations[-1].usage if invocations else {}

    logger.info(json.dumps({
        "event": "strands_invoke",
        "session_id": session_id,
        "composed_skill_ids": list(composed.skill_ids),
        "stop_reason": result.stop_reason,
        "cycle_count": result.metrics.cycle_count,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
        "tool_calls": len(result.metrics.tool_metrics),
    }))

    return {
        "response": str(result),
        "tool_calls": [],
        "guardrail_result": {
            "action": "GUARDRAIL_INTERVENED"
                      if result.stop_reason == "guardrail_intervened"
                      else "NONE",
        },
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "latency_ms": latency_ms,
        "composed_skill_ids": list(composed.skill_ids),
    }
```

Notice what is absent compared to Phase 1:
- No `@tool` definitions
- No `_lambda_client` or `_bedrock_agent_runtime` boto3 clients
- No `KNOWLEDGE_BASE_ID` env var read
- No hardcoded skill IDs
- No startup-time system prompt composition
- No `S3SessionManager` (replaced by AgentCore Memory adapter)

### 2.8 Strands Agentic Loop

With skills composed per invocation, the Strands loop on each turn:

1. **Compose** — `skills_loader.compose(skill_ids)` pulls SKILL.md bodies from S3
   (cache hits in steady state), wraps each in `<skill>` tags, and prepends the
   precedence preamble. The resulting system prompt teaches the model its role,
   citation format, tool usage rules, and hard constraints for this turn.
2. **Reason** — LLM reads the composed prompt + conversation history from AgentCore
   Memory + the user's new message. Decides next action per skill instructions.
3. **Tool select** — LLM chooses a Gateway tool (e.g., `search_hr_documents`) because
   the skill explicitly instructs it to. The skill drives the decision; the tool
   schema is only for arg formatting.
4. **Execute** — Strands invokes the Gateway tool. Gateway routes to Lambda. Lambda
   calls the backing API (Bedrock KB, Glean stub). Standard result JSON returns.
5. **Answer** — LLM constructs a cited answer per baseline citation rules.
6. **Persist** — AgentCore Memory writes the turn to shared session storage; the
   next turn (same or different agent) reads the same history.

### 2.9 AgentCore Memory Adapter

`memory_adapter.py` wraps AgentCore Memory as a Strands `session_manager` interface.
Replaces `S3SessionManager` from Phase 1. Shared across supervisor + sub-agents so
the escalation sub-agent sees the policy sub-agent's turn in the same session.

```python
# ai_platform/shared/memory_adapter.py
"""
AgentCore Memory adapter conforming to the Strands session_manager protocol.
Replaces strands.session.S3SessionManager.
"""
# Implementation depends on AgentCore Memory SDK API.
# Placeholder interface — finalize during Phase 2.3 build.

def get_memory_session(memory_id: str, session_id: str, region_name: str):
    ...
```

Full adapter implementation is a Phase 2.3 deliverable — pending AgentCore Memory
SDK exploration. Interface is frozen here so callers are stable.

---

## Section 3 — Orchestrator Design

### 3.1 Universal Entry Point

The orchestrator is itself an AgentCore Runtime running the same generic agent
shell (`agent_strands.py`) with a different skill configuration. Every user request
enters through the orchestrator's AgentCore Runtime endpoint — there is no direct
path to a domain sub-agent.

**Why no bypass:** Global rules (auth, PII, audit, rate limit) are enforced by
orchestrator container middleware. Skipping the orchestrator skips all of them.
The latency cost for simple requests is the cost of consistent global rule enforcement.

### 3.2 IoC Statement

Without a routing skill, the orchestrator would contain `if domain == "hr": ...` in
Python. That routing logic is domain knowledge embedded in platform code. The
orchestrator inverts this: callers know one endpoint; `platform/orchestrator@v1.0.0`
decides which sub-agent to dispatch; the agent registry maps domain → runtime ARN.

A new domain (Finance, Legal) means:
1. A new domain skill published to S3.
2. A new sub-agent Terraform layer whose registry entry declares `domains: ["finance.expense"]`.
3. A new version of `platform/orchestrator@v1.0.0` with routing rules for the new domain.

Orchestrator Python code does not change. `base_agent.py` does not change.
`agent_strands.py` does not change.

### 3.3 AWS Reference Pattern Alignment

This architecture implements the AWS "Multi-Agent Orchestration on AWS" reference
pattern (AWS Reference Architecture, reviewed for technical accuracy 2025-05-27).

| AWS Reference Term | This Architecture |
| --- | --- |
| Supervisor Agent (AgentCore Runtime, Strands Agent) | `agents/orchestrator/` — generic shell + `platform/orchestrator@v1.0.0` |
| Specialized Agent (AgentCore Runtime, Strands Agent) | `agents/hr-assistant-strands/` — generic shell + domain skill dispatched per invocation |
| Foundation Model | `us.anthropic.claude-sonnet-4-6` (Bedrock) |
| AgentCore Memory (cross-agent context) | Shared `memory_id` across supervisor and sub-agents for the same session |
| AgentCore Gateway + Lambda Tools | `search_hr_documents`, `glean_search` Lambdas |
| AgentCore Observability + CloudWatch | Automatic metrics/flows/traces + structured audit logs from orchestrator middleware |
| "Securely authenticated requests" | IAM-signed AgentCore invocation (Cognito + JWT deferred to post-Phase-2) |

Deviations documented in the Decision Log:
- Cognito JWT replaced by IAM auth + `user_role` in payload body for dev (item 3).
- Skills layer is our own addition on top of the AWS pattern.

### 3.4 HR Request Routing — Concrete Trace

**Request:** "I'm being harassed by my manager and want to know what my rights are
under the parental leave policy."

Payload:
```json
{
  "prompt": "I'm being harassed by my manager and ...",
  "sessionId": "session-abc123",
  "user_role": "hr-employee"
}
```

**Orchestrator container middleware (inbound):**
1. AgentCore Runtime validates IAM signature on the invocation.
2. Middleware extracts `user_role = "hr-employee"` from payload. Present → proceed.
3. Rate check: session under 20 req/60s → proceed.
4. `comprehend.detect_pii_entities(Text=...)` returns no PII → message unchanged.
5. `audit_log`: `event=request_received, session_id=session-abc123, user_role=hr-employee, pii_detected=false`.

**Orchestrator Strands Agent invocation:**
- Composes `[platform/agent-behavior@v1.0.0, platform/orchestrator@v1.0.0]` into system prompt.
- LLM reads the message, identifies both harassment signal AND parental leave signal.
- LLM classifies as `hr.both`.
- LLM invokes `dispatch_agent` tool twice in parallel:
  ```
  dispatch_agent(domain="hr.policy",     message=<redacted>)
  dispatch_agent(domain="hr.escalation", message=<redacted>)
  ```

**`dispatch_agent` Strands tool (internal):**
- Looks up domain in orchestrator's in-memory registry map (populated at startup).
- `hr.policy → hr-assistant-strands-dev` runtime ARN; dispatched skill_ids = `[hr/policy-lookup@v1.0.0]`.
- `hr.escalation → hr-assistant-strands-dev` runtime ARN; dispatched skill_ids = `[hr/escalation-procedure@v1.0.0]`.
- For each, calls `bedrock-agentcore.invoke_agent_runtime()` with payload:
  ```json
  {
    "prompt": "<message>",
    "sessionId": "session-abc123",
    "user_role": "hr-employee",
    "skill_ids": ["hr/policy-lookup@v1.0.0"]
  }
  ```
- Returns sub-agent responses to the orchestrator's Strands loop.

**Sub-agent execution (both in parallel):**
- Sub-agent A composes `[platform/agent-behavior@v1.0.0, hr/policy-lookup@v1.0.0]`.
- Sub-agent B composes `[platform/agent-behavior@v1.0.0, hr/escalation-procedure@v1.0.0]`.
- Both read the same `sessionId` from AgentCore Memory — shared conversation context.
- A calls `search_hr_documents(query="parental leave policy rights")`, constructs cited answer.
- B follows escalation protocol → EAP contact → escalation summary.

**Orchestrator synthesis (LLM emits deterministic template):**
The orchestrator skill's Response Synthesis section instructs the LLM to produce:
```
[escalation response]

---

In addition to connecting you with HR support, here is the information you asked about:

[policy response]
```

**Orchestrator container middleware (outbound):**
- `audit_log`: `event=response_sent, session_id=..., domain=hr.both, agents_dispatched=2, response_chars=1340`.
- Return synthesized response to caller.

### 3.5 Dispatch Patterns

| Request type | Dispatch | Justification |
| --- | --- | --- |
| Pure policy | 1 sub-agent, serial | One task, no decomposition benefit |
| Pure escalation | 1 sub-agent, serial | One task, emotional continuity is better single-threaded |
| Policy + escalation | 2 sub-agents, parallel | Independent tasks; parallel halves total latency |
| Unknown domain | No dispatch | Orchestrator responds directly with redirect |

### 3.6 Response Synthesis

**Single-dispatch:** return sub-agent response unchanged.

**Parallel dispatch:** deterministic template in `platform/orchestrator@v1.0.0`
Response Synthesis section — escalation first, fixed separator + bridging sentence,
policy second. LLM follows template verbatim; no LLM-freestyle merging.

**Partial failure:** successful response + short inline note directing the user to
the missing channel (per skill's Partial failure rules).

### 3.7 Global Rules Enforcement

| Rule | Where enforced | Mechanism |
| --- | --- | --- |
| IAM authentication | AgentCore Runtime boundary | Runtime validates signature; middleware reads resolved caller identity |
| `user_role` extraction | Orchestrator container middleware (inbound) | From payload body; reject if absent |
| Rate limiting | Orchestrator container middleware (inbound) | DynamoDB counter per session with TTL |
| PII detection + redaction | Orchestrator container middleware (inbound) | `comprehend.detect_pii_entities`; unconditional |
| Platform guardrail | Sub-agent `BedrockModel` invocation | Guardrail ID passed to `BedrockModel`; enforced by Bedrock |
| Audit logging | Orchestrator container middleware (both) | Structured JSON to CloudWatch + AgentCore Observability metrics |
| Session management | AgentCore Memory | Shared across supervisor and sub-agents for a session |

**Why PII and audit are middleware, not Strands tools:**
They are unconditional global rules. An LLM tool is invoked at the LLM's discretion
— that makes them bypassable, which is unacceptable for PII and audit. Middleware
runs on every request without LLM involvement.

### 3.8 Agent Registry Discovery

The orchestrator scans the extended DynamoDB registry (`ai-platform-dev-agent-registry`)
at startup and builds an in-memory map:

```python
# orchestrator startup
registry = scan_registry_enabled(table_name=_REGISTRY_TABLE)

domain_map: dict[str, dict] = {}
for entry in registry:
    for domain in entry["domains"]:
        domain_map[domain] = {
            "agent_id":          entry["agent_id"],
            "runtime_arn":       entry["runtime_arn"],
            "available_skills":  entry["available_skills"],
            "baseline_skills":   entry["baseline_skills"],
        }

# dispatch_agent resolves domain → dispatch target via this map
```

Map is cached for the container's lifetime. Adding a new agent requires an
orchestrator restart — acceptable because agent additions happen at apply-time
(minutes-scale), not request-time (seconds-scale).

Domain lookup via full table scan. Expected agent count (5-10 foreseeable) makes
scan cheap; no GSI needed.

### 3.9 `dispatch_agent` Strands Tool

```python
# agents/orchestrator/container/app/tools/dispatch_agent.py
"""
Strands @tool that the orchestrator LLM invokes to route to a sub-agent.
Resolves domain → runtime ARN via the in-memory registry map built at startup.
"""
from __future__ import annotations

import json
import os
import boto3
from strands import tool

_agentcore = boto3.client("bedrock-agentcore", region_name=os.environ["AWS_REGION"])

# Populated at startup by main.py from DynamoDB registry scan.
_domain_map: dict[str, dict] = {}


def set_domain_map(domain_map: dict[str, dict]) -> None:
    global _domain_map
    _domain_map = domain_map


@tool
def dispatch_agent(domain: str, message: str, session_id: str, user_role: str) -> dict:
    """
    Dispatch a request to a sub-agent registered for the given domain.

    Args:
        domain: e.g. "hr.policy", "hr.escalation"
        message: the redacted user message
        session_id: session identifier (shared via AgentCore Memory)
        user_role: resolved user role from orchestrator middleware

    Returns:
        {"response": "...", "domain": "...", "agent_id": "..."}
    """
    entry = _domain_map.get(domain)
    if entry is None:
        return {
            "error": f"no agent registered for domain: {domain}",
            "response": "",
            "domain": domain,
        }

    # Determine which skills to dispatch for this domain.
    # Convention: domain-code "hr.policy" → skill "hr/policy-lookup"
    skill_ids = _skills_for_domain(domain, entry["available_skills"])

    payload = json.dumps({
        "prompt": message,
        "sessionId": session_id,
        "user_role": user_role,
        "skill_ids": skill_ids,
    }).encode()

    resp = _agentcore.invoke_agent_runtime(
        agentRuntimeArn=entry["runtime_arn"],
        runtimeSessionId=session_id,
        payload=payload,
    )
    body = json.loads(resp["response"].read())

    return {
        "response": body.get("response", ""),
        "domain": domain,
        "agent_id": entry["agent_id"],
    }


def _skills_for_domain(domain: str, available_skills: list[str]) -> list[str]:
    """
    Map domain code to the skill in the sub-agent's available_skills.
    Convention: "hr.policy" → matches "hr/policy-lookup@v1.0.0".
    """
    # Domain "hr.policy" → skill path contains "policy"; "hr.escalation" → contains "escalation"
    qualifier = domain.split(".", 1)[1] if "." in domain else domain
    for sid in available_skills:
        if qualifier in sid:
            return [sid]
    raise ValueError(
        f"no skill in available_skills matches domain {domain!r}: {available_skills}"
    )
```

The parallel dispatch case (`hr.both`) is handled by the Strands Agent invoking
`dispatch_agent` twice in the same turn — Strands' built-in tool-use loop
supports parallel tool calls natively.

---

## Section 4 — Tool Architecture

### 4.1 Gateway-First Principle

**What was inverted:** In Phase 1, infrastructure details live in the agent container:
- `_bedrock_agent_runtime = boto3.client("bedrock-agent-runtime")` — the agent knows it talks to Bedrock.
- `KNOWLEDGE_BASE_ID` — the agent knows which KB.
- `FunctionName="ai-platform-dev-glean-stub"` — the agent knows the Glean Lambda name.

These are infrastructure decisions encoded in application code. Changing any of them
requires container code changes and redeployment.

The Gateway-first pattern inverts this: the agent knows only tool names. Infrastructure
details live in Lambda environment variables, managed by Terraform. Changing the KB ID
is a `terraform apply` on the tool Lambda, not a container rebuild.

### 4.2 search_hr_documents

**Lambda responsibility:** Accepts a search query and retrieves relevant passages from
the HR Policies Knowledge Base using the Bedrock KB API. KB ID loaded from env var.

```python
# lambdas/search_hr_documents/handler.py
import os
import boto3

_REGION = os.environ.get("AWS_REGION", "us-east-2")
_KB_ID = os.environ["KNOWLEDGE_BASE_ID"]
_bedrock = boto3.client("bedrock-agent-runtime", region_name=_REGION)


def lambda_handler(event: dict, context) -> dict:
    """
    Input:  {"query": "annual leave entitlement", "top_k": 5}
    Output: {"results": [{"text": "...", "source": "...", "score": 0.0}]}
    Error:  {"error": "...", "results": []}
    """
    query = event.get("query", "")
    top_k = int(event.get("top_k", 5))

    if not query:
        return {"error": "query is required", "results": []}

    try:
        resp = _bedrock.retrieve(
            knowledgeBaseId=_KB_ID,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {"numberOfResults": top_k}
            },
        )
        results = [
            {
                "text": r.get("content", {}).get("text", ""),
                "source": r.get("location", {}).get("s3Location", {}).get("uri", ""),
                "score": float(r.get("score", 0.0)),
            }
            for r in resp.get("retrievalResults", [])
            if r.get("content", {}).get("text")
        ]
        return {"results": results}

    except Exception as exc:
        return {"error": str(exc), "results": []}
```

**Why Bedrock KB (not direct AOSS):** Bedrock KB handles embedding generation
internally (`amazon.titan-embed-text-v2:0`). The Lambda does not need to know the
AOSS index schema. Switching embedding models is a KB configuration change.

### 4.3 glean_search

```python
# lambdas/glean_search/handler.py
import json
import os
import boto3

_REGION = os.environ.get("AWS_REGION", "us-east-2")
_GLEAN_LAMBDA = os.environ["GLEAN_LAMBDA_NAME"]
_lambda = boto3.client("lambda", region_name=_REGION)


def lambda_handler(event: dict, context) -> dict:
    """
    Input:  {"query": "...", "top_k": 5}
    Output: {"results": [{"text": "...", "source": "...", "score": 0.0}]}
    Error:  {"error": "...", "results": []}
    """
    query = event.get("query", "")
    top_k = int(event.get("top_k", 5))

    if not query:
        return {"error": "query is required", "results": []}

    mcp_event = {
        "body": json.dumps({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "search",
                "arguments": {"query": query, "maxResults": top_k},
            },
        }),
        "requestContext": {"http": {"method": "POST"}},
        "rawPath": "/",
    }

    try:
        resp = _lambda.invoke(
            FunctionName=_GLEAN_LAMBDA,
            Payload=json.dumps(mcp_event).encode(),
        )
        payload = json.loads(resp["Payload"].read())
        body = json.loads(payload.get("body", "{}"))
        content = body.get("result", {}).get("content", [])

        results = []
        for item in content:
            text = item.get("text", "")
            if text:
                results.append({"text": text, "source": "glean", "score": 0.0})

        return {"results": results}

    except Exception as exc:
        return {"error": str(exc), "results": []}
```

**Phase 3 upgrade path:** Replace `_lambda.invoke(...)` with a direct Glean API call.
Output shape stays identical. No agent or skill changes required.

### 4.4 Standard Result Contract

Both tools return:

```json
{
  "results": [
    {
      "text": "string — retrieved passage content",
      "source": "string — document URI or 'glean'",
      "score": 0.0
    }
  ]
}
```

Error contract:
```json
{"error": "string — error message", "results": []}
```

**Why identical shape matters:** `hr/policy-lookup@v1.0.0` calls `search_hr_documents`
first and `glean_search` as fallback. Identical shape means the skill has no branching
logic. Adding a third retrieval source requires only a new Lambda with the same output
shape — zero skill updates.

### 4.5 AgentCore Gateway Registration — Terraform Documentation

```hcl
# terraform/dev/tools/search-hr-documents/main.tf
resource "aws_lambda_function" "search_hr_documents" {
  function_name = "${var.project_name}-${var.environment}-search-hr-documents"
  filename      = data.archive_file.handler.output_path
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  role          = aws_iam_role.search_hr_documents.arn

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = var.knowledge_base_id
      AWS_REGION        = var.aws_region
    }
  }
}

resource "aws_bedrock_agent_core_gateway_target" "search_hr_documents" {
  gateway_id  = data.terraform_remote_state.platform.outputs.mcp_gateway_id
  name        = "search_hr_documents"
  description = "HR Policies Knowledge Base retrieval via Bedrock KB API."

  target_configuration {
    lambda { lambda_arn = aws_lambda_function.search_hr_documents.arn }
  }
}
```

```hcl
# terraform/dev/tools/glean-search/main.tf
resource "aws_lambda_function" "glean_search" {
  function_name = "${var.project_name}-${var.environment}-glean-search"
  filename      = data.archive_file.handler.output_path
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  role          = aws_iam_role.glean_search.arn

  environment {
    variables = {
      GLEAN_LAMBDA_NAME = "${var.project_name}-${var.environment}-glean-stub"
    }
  }
}

resource "aws_bedrock_agent_core_gateway_target" "glean_search" {
  gateway_id  = data.terraform_remote_state.platform.outputs.mcp_gateway_id
  name        = "glean_search"
  description = "Glean enterprise search — stub in dev, real API in Phase 3."

  target_configuration {
    lambda { lambda_arn = aws_lambda_function.glean_search.arn }
  }
}
```

Both Lambdas follow ADR-017 (inline IAM ownership — role defined in the tool layer,
not in platform or agent layers).

---

## Section 5 — Implementation Plan

Phases are scoped as sub-phases of the larger Strands migration. Strands Phase 1
(boto3 → Strands agent) was completed on 2026-04-19 (PR #31).

### Phase 2.1 — Skills Layer Build

**What is built:**
- Four SKILL.md files published to S3 at versioned paths:
  - `skills/platform/agent-behavior/v1.0.0/SKILL.md`
  - `skills/platform/orchestrator/v1.0.0/SKILL.md`
  - `skills/hr/policy-lookup/v1.0.0/SKILL.md`
  - `skills/hr/escalation-procedure/v1.0.0/SKILL.md`
- `ai_platform/shared/skills_loader.py` with `parse_skill_ref()`, `_fetch_skill()`,
  `_split_frontmatter()`, and `compose()` returning `ComposedSkills`.
- Unit tests for `skills_loader.py` with mocked S3.
- Platform layer additions: skills S3 bucket (versioned, no Object Lock in dev),
  IAM prefix-scoped read policies.

**Acceptance criteria:**
- `parse_skill_ref("hr/policy-lookup")` raises `ValueError`.
- `parse_skill_ref("hr/policy-lookup@v1.0.0")` returns `("hr/policy-lookup", "v1.0.0")`.
- `compose(["hr/policy-lookup@v1.0.0", "platform/agent-behavior@v1.0.0"], bucket)`
  returns a `ComposedSkills` whose `system_prompt` starts with the precedence preamble,
  then contains two `<skill name="..." version="...">` blocks.
- `compose()` with conflicting `model:` declarations across skills raises
  `SkillCompositionError`.
- S3 fetch cached: two `compose()` calls with the same skill_ids → `boto3.get_object`
  called exactly once per unique `(path, version)` (verified via mock count).
- Composed `system_prompt` contains anchor phrases: `"According to"`, `"Hard Constraints"`.

**Dependencies:** None. Self-contained. Can start immediately.

---

### Phase 2.2 — Tool Layer Build

**What is built:**
- `lambdas/search_hr_documents/handler.py`
- `lambdas/glean_search/handler.py`
- `terraform/dev/tools/search-hr-documents/` layer
- `terraform/dev/tools/glean-search/` layer (replaces `tools/glean/` at cutover)
- Gateway target registration for both tools
- Integration tests against real Gateway + Lambda

**Acceptance criteria:**
- Both Lambdas return identical JSON shape for valid queries.
- Both return `{"error": "...", "results": []}` on failure.
- No hardcoded KB IDs, Lambda names, or ARNs in handler code.
- `aws bedrock-agentcore-control list-gateway-targets` shows both tools for the
  platform Gateway.

**Dependencies:** Phase 2.1 complete. Platform layer applied (Gateway exists).

---

### Phase 2.3 — Agent Layer Build

**What is built:**
- `ai_platform/shared/base_agent.py` — `AgentConfig` dataclass
- `ai_platform/shared/tool_registry.py` — `get_gateway_tools(endpoint, tool_ids)` resolving
  Gateway tool IDs to Strands tool objects via MCPClient
- `ai_platform/shared/memory_adapter.py` — AgentCore Memory → Strands `session_manager`
- `agents/hr-assistant-strands/container/app/skills_config.py` — factory functions
- Updated `agent_strands.py` — per-invocation composition signature
- Updated `main.py` — `SKILLS_ENABLED` routing (see Section 6.2)
- AgentCore Memory resource provisioned in platform layer

**Acceptance criteria:**
- Agent starts with `SKILLS_ENABLED=true` and required env vars set.
- `agent_strands.py` contains zero `@tool` definitions (grep).
- `agent_strands.py` contains zero imports of `bedrock-agent-runtime` or `lambda` clients (grep).
- `agent_strands.py` contains zero mentions of `"HR"`, `"policy"`, `"leave"`, `"KB"`, `"knowledge_base"` (grep).
- `invoke(session_id, user_message, skill_ids)` composes the prompt per call; every
  invocation log includes `composed_skill_ids`.
- Dispatched `skill_ids` outside `available_skills ∪ baseline_skills` raises `ValueError`.
- `get_hr_assistant_config()` raises `KeyError` if any required env var is absent.
- AgentCore Memory round-trip: two `invoke()` calls with the same `session_id` show
  the first turn's content in the second turn's context.

**Dependencies:** Phase 2.1 (skills in S3), Phase 2.2 (Gateway tools registered),
platform layer extended with AgentCore Memory resource.

---

### Phase 2.4 — Orchestrator Layer Build

**What is built:**
- `terraform/dev/agents/orchestrator/` layer, peer to `agents/hr-assistant-strands/`
- Orchestrator container: same generic `agent_strands.py` + `platform/orchestrator` skill
- Orchestrator middleware: auth check, rate limit (DynamoDB counter), Comprehend
  PII detection, structured audit log
- `dispatch_agent` Strands `@tool` + registry-backed domain map
- Extended DynamoDB registry schema populated by each agent's Terraform layer

**Acceptance criteria:**
- Orchestrator runtime accepts IAM-signed invocations at its AgentCore Runtime endpoint.
- Orchestrator startup log shows `domain_map_loaded` with domain count > 0.
- Every request produces inbound and outbound audit log records in CloudWatch.
- Request without `user_role` in payload → rejected with structured `auth_reject` log; zero `invoke_agent_runtime` calls.
- Request with PII (test SSN/email) → `pii_detected` log event; redacted message visible in sub-agent invocation payload.
- 21st request in 60 seconds from same session → rejected with 429.
- `agents/orchestrator/` layer applies independently of `agents/hr-assistant-strands/`.

**Dependencies:** Phase 2.3 complete (generic shell stable).

---

### Phase 2.5 — Integration and Validation

**What is built:**
- End-to-end smoke tests covering orchestrator → sub-agent → Gateway → Lambda → Bedrock KB
- A/B comparison harness: Phase 1 (direct Strands) vs skills-driven path
- LLM-as-Judge evaluation (faithfulness, relevance)
- AgentCore Observability verification (metrics visible in CloudWatch)

**Acceptance criteria:**
Full test matrix:

| Test | What it tests |
| --- | --- |
| 8a | Annual leave returns "25" — KB grounded answer |
| 8b | Guardrail blocks legal advice |
| 8c | Distress returns "1800-EAP-HELP" |
| 8d | Prompt Vault Lambda write path (parallel during transition) |
| 8e | CloudWatch `strands_invoke` event present |
| 8f | `tool_call` event with `tool_name=search_hr_documents` (moved from `kb_retrieve` in agent logs to Lambda logs) |
| **8g** | **Composition correctness.** For a pure policy request, the captured composed prompt contains `<skill name="platform/agent-behavior"`, `<skill name="hr/policy-lookup"`, anchor phrases `"According to"` and `"search_hr_documents"`, and does NOT contain `<skill name="hr/escalation-procedure"`. |
| **8h** | **Tool wiring.** Policy query end-to-end; `search_hr_documents` Lambda CloudWatch log shows the invocation; response contains a `.pdf` citation from the HR docs bucket. |
| **8i** | **Orchestrator routing.** Three assertions: pure policy → single dispatch, log shows `dispatch_decision{domain=hr.policy}`. Pure escalation → single dispatch, response contains `1800-EAP-HELP` and `Escalation summary`. Combined → two `invoke_agent_runtime` calls, final response contains `In addition to connecting you with HR support`. |
| **8j** | **Auth negative path.** Invocation without `user_role` → orchestrator rejects; `auth_reject` log; zero sub-agent dispatches. |
| **8k** | **PII middleware.** Request with test SSN/email → `pii_detected` log with entity types; redacted message visible in sub-agent input log; original only in audit record. |
- No regression in LLM-as-Judge faithfulness or relevance scores.
- AgentCore Observability metrics visible for orchestrator + sub-agent runtimes.
- Cutover checklist (Section 6.5) complete.

**Dependencies:** Phases 2.1-2.4 complete.

---

## Section 6 — Migration from Current Implementation

### 6.1 Behavior Mapping

The Strands Phase 1 implementation has these behaviors; each maps to a skill or Lambda:

**Behavior 1: KB Retrieval** — Phase 1 `@tool retrieve_hr_documents` (agent_strands.py).
Control moves to: `hr/policy-lookup@v1.0.0` (when) + `search_hr_documents` Lambda (how).

**Behavior 2: Grounded Q&A** — Phase 1 Bedrock Prompt Management text.
Control moves to: `platform/agent-behavior@v1.0.0` (citation, confidence) +
`hr/policy-lookup@v1.0.0` (retrieval protocol, output format).

**Behavior 3: Escalation** — Phase 1 Bedrock Prompt Management text.
Control moves to: `hr/escalation-procedure@v1.0.0` (full protocol, triggers, EAP, handoff).

**Behavior 4: Glean Search** — Phase 1 `@tool glean_search`, implicit when-to-call.
Control moves to: `hr/policy-lookup@v1.0.0` Step 5 (when) + `glean_search` Lambda (how).

**Behavior 5: Session continuity** — Phase 1 `S3SessionManager` bucket+prefix.
Replaced by: AgentCore Memory resource, shared across supervisor and sub-agents.

**Behavior 6: Routing (new in Phase 2)** — No Phase 1 equivalent; previously every
request went directly to the HR agent. Now every request enters via orchestrator.

### 6.2 SKILLS_ENABLED Switching

`main.py` routes between Phase 1 behavior (Bedrock Prompt Management + `@tool`) and
Phase 2 behavior (skills composed + Gateway tools) via the `SKILLS_ENABLED` env var.
Both implementations coexist in the same container image during the transition.

```python
# main.py — startup hook (skills routing)
@app.on_event("startup")
async def startup() -> None:
    from app import agent_strands, vault
    _AGENT_ID = "hr-assistant-strands-dev"
    skills_enabled = os.environ.get("SKILLS_ENABLED", "false").lower() == "true"

    if skills_enabled:
        # Phase 2 path — per-invocation composition
        from ai_platform.shared import tool_registry
        from app.skills_config import get_hr_assistant_config

        config = get_hr_assistant_config()
        gateway_tools = tool_registry.get_gateway_tools(
            config.gateway_endpoint,
            config.gateway_tool_ids,
        )
        agent_strands.init(config, gateway_tools)

        logger.info(json.dumps({
            "event": "startup_mode",
            "skills_enabled": True,
            "available_skills": config.available_skills,
            "baseline_skills": config.baseline_skills,
            "memory_id": config.memory_id,
        }))

    else:
        # Phase 1 path — unchanged from current implementation
        _startup_phase1_legacy()
        logger.info(json.dumps({"event": "startup_mode", "skills_enabled": False}))
```

The Phase 1 startup (`_startup_phase1_legacy`) is the current `startup()` implementation
extracted verbatim. `agent_strands.init_legacy()` retains the Phase 1 signature during transition.

**Per-invocation entry point (Phase 2):** `invoke()` now reads `skill_ids` from the
incoming request payload. The orchestrator provides them; direct invocations (smoke
tests) supply them explicitly.

### 6.3 Parallel Operation

During the transition:
- `hr-assistant-strands-dev` runtime runs with `SKILLS_ENABLED=false` (Phase 1).
- `hr-assistant-strands-skills-dev` runtime runs with `SKILLS_ENABLED=true` (Phase 2).
- Both use the same container image tag, differing only in env var.
- Smoke tests run against both.
- LLM-as-Judge evaluations compare response quality.
- No user traffic on the skills runtime until cutover criteria are met.

### 6.4 Session Storage Migration

Phase 1 sessions (`S3SessionManager` → `s3://bucket/strands-sessions/hr-assistant/...`)
do not migrate forward. Skills runtime starts with empty AgentCore Memory. Active
sessions at cutover continue on the Phase 1 runtime until they end naturally.
The Phase 1 DynamoDB session table (`ai-platform-dev-agent-session`) can be left
in place during parallel operation and destroyed post-cutover.

### 6.5 Cutover Criteria

Must all be satisfied before `SKILLS_ENABLED=false` is retired:

- [ ] All 8/8 smoke tests pass on skills-enabled runtime (8a-8k per Section 5 matrix)
- [ ] No regression in LLM-as-Judge faithfulness score (≥ Phase 1 baseline ± 0.05)
- [ ] No regression in LLM-as-Judge relevance score (≥ Phase 1 baseline ± 0.05)
- [ ] AgentCore Observability metrics visible for orchestrator + sub-agent runtimes
- [ ] At least 48 hours of parallel operation with zero orchestrator or sub-agent errors
- [ ] Orchestrator routes correctly in staging (8i passes there too)
- [ ] ADR drafted and reviewed: "Skills-driven IoC architecture for AI agents"
- [ ] `system_prompt_arn` removed from DynamoDB agent registry for Strands agents
- [ ] Bedrock Prompt Management artifact retired (no longer read at startup)
- [ ] Phase 1 DynamoDB session table destroyed
- [ ] `init_legacy()` and `SKILLS_ENABLED=false` branch removed from `main.py` / `agent_strands.py`
- [ ] Staging/prod skills buckets provisioned with Object Lock + Governance mode

---

## Section 7 — IoC Validation

Validates the architectural claim: "Domain behavior is fully controlled by skills.
The agent shell contains zero domain knowledge. Adding a new domain capability
requires no agent code changes — only a new skill."

### Claim 1: "The agent shell contains zero domain knowledge."

**Evidence from Section 2.7 — post-migration `agent_strands.py` structure:**

```
agent_strands.py imports:
  strands.Agent
  strands.models.bedrock.BedrockModel
  strands.agent.conversation_manager.SlidingWindowConversationManager
  ai_platform.shared.base_agent.AgentConfig
  ai_platform.shared.skills_loader
  ai_platform.shared.tool_registry
  ai_platform.shared.memory_adapter

agent_strands.py does NOT import:
  boto3.client("bedrock-agent-runtime")   ← removed
  boto3.client("lambda")                  ← removed
  Any HR-specific module                  ← no such imports exist

agent_strands.py contains:
  init(config: AgentConfig, gateway_tools: list)
  invoke(session_id: str, user_message: str, skill_ids: list[str]) → dict

agent_strands.py does NOT contain:
  Any @tool definition for domain tools    ← zero
  Any hardcoded prompt text                ← zero
  Any domain-specific env var read         ← zero
  Any knowledge_base_id reference          ← zero
  Any lambda function name reference       ← zero
  Any mention of "HR", "policy", "leave"   ← zero
  Any startup-time prompt composition      ← composition is per-invocation
```

**Verification commands (post-implementation):**

```bash
grep -n "@tool" container/app/agent_strands.py           # must be empty
grep -n "bedrock-agent-runtime" container/app/agent_strands.py
grep -n "knowledge_base_id" container/app/agent_strands.py
grep -in "KNOWLEDGE_BASE" container/app/agent_strands.py
grep -n "glean-stub" container/app/agent_strands.py
grep -iEn "\\bHR\\b|policy|leave" container/app/agent_strands.py
```

All commands must return zero matches for the claim to hold.

**Verdict: Supported.** The agent shell contains no domain knowledge. Domain behavior
arrives via `skill_ids` (per invocation) + `gateway_tools` (resolved by name).

---

### Claim 2: "Domain behavior is fully controlled by skills."

| Behavior | Phase 1 owner | Phase 2 skill owner |
| --- | --- | --- |
| Always retrieve before answering | `@tool retrieve_hr_documents` docstring | `hr/policy-lookup@v1.0.0`, Retrieval Protocol Step 1 |
| How to formulate KB queries | Not explicit — LLM ad-hoc | `hr/policy-lookup@v1.0.0`, Step 2 query formulation table |
| When to use Glean as fallback | Not explicit — tool docstring only | `hr/policy-lookup@v1.0.0`, Step 5 |
| Citation format | Bedrock Prompt Management (opaque) | `platform/agent-behavior@v1.0.0` |
| No-results behavior | Not explicit | `hr/policy-lookup@v1.0.0`, Step 6 |
| Escalation triggers | Bedrock Prompt Management (opaque) | `hr/escalation-procedure@v1.0.0` Mandatory Escalation Triggers |
| EAP contact (1800-EAP-HELP) | Bedrock Prompt Management (opaque) | `hr/escalation-procedure@v1.0.0` Step 3 |
| Escalation information collection | Not explicit | `hr/escalation-procedure@v1.0.0` Step 2 |
| Response tone for distress | Bedrock Prompt Management (opaque) | `platform/agent-behavior@v1.0.0` Tone for Sensitive Conversations |
| Routing (new in Phase 2) | n/a — no orchestrator | `platform/orchestrator@v1.0.0` |
| Multi-agent synthesis (new in Phase 2) | n/a | `platform/orchestrator@v1.0.0` Response Synthesis section |

**Verdict: Supported.** Every domain behavior is expressible by reading a SKILL.md file.

---

### Claim 3: "Adding a new domain capability requires no agent code changes."

**Hypothetical: Adding a Finance Assistant**

1. **Write `finance/expense-policy@v1.0.0` SKILL.md.** Publish to
   `s3://skills-bucket/skills/finance/expense-policy/v1.0.0/SKILL.md`.

2. **Deploy `search_finance_documents` Lambda.** Apply
   `terraform/dev/tools/search-finance-documents/`. Register as Gateway target.

3. **Create `agents/finance-assistant/container/app/skills_config.py`:**
   ```python
   def get_finance_assistant_config() -> AgentConfig:
       return AgentConfig(
           available_skills=["finance/expense-policy@v1.0.0"],
           baseline_skills=["platform/agent-behavior@v1.0.0"],
           gateway_tool_ids=["search_finance_documents"],
           ...
       )
   ```

4. **Apply `agents/finance-assistant/` Terraform layer.** Writes registry entry with
   `domains: ["finance.expense"]`. Same container image as HR assistant.

5. **Update `platform/orchestrator@v1.0.0`** — add `finance.expense` to domain table.
   Publish `v1.1.0`. Deploy new orchestrator container image.

**Files that are NOT touched:**
- `ai_platform/shared/base_agent.py`
- `ai_platform/shared/skills_loader.py`
- `ai_platform/shared/tool_registry.py`
- `ai_platform/shared/memory_adapter.py`
- `agents/hr-assistant-strands/container/app/agent_strands.py`
- `agents/hr-assistant-strands/container/app/main.py`
- `agents/hr-assistant-strands/container/app/skills_config.py`

The Finance Assistant uses the same container image as the HR Assistant. Only
`skills_config.py` differs, and that file contains only skill IDs and tool IDs.

**Verdict: Supported.**

---

### Claim 4: "The orchestrator makes runtime injection decisions."

**Request A** (T=0): "How many days of sick leave am I entitled to?"
- Orchestrator classifies: `hr.policy`
- `dispatch_agent(domain="hr.policy", ...)` resolves via registry → HR runtime ARN
- Sub-agent receives `skill_ids=["hr/policy-lookup@v1.0.0"]`, composes per turn
- Gateway tools: `search_hr_documents`, `glean_search`

**Request B** (T=5, different session): "I want to file a complaint about my manager."
- Orchestrator classifies: `hr.escalation`
- `dispatch_agent(domain="hr.escalation", ...)`
- Sub-agent receives `skill_ids=["hr/escalation-procedure@v1.0.0"]`
- Gateway tools: none used by the skill

**Request C** (T=10, different session): "I'm being harassed and want to know my parental leave rights."
- Orchestrator classifies: `hr.both`
- `dispatch_agent` called twice in parallel (different domain args)
- Sub-agent A gets `hr/policy-lookup`; Sub-agent B gets `hr/escalation-procedure`
- Orchestrator synthesizes per template

Same container image, same generic `agent_strands.py`, produces three distinct
behaviors based on per-invocation skill dispatch. No code branching. No agent-side
domain logic.

The routing decision itself is controlled by `platform/orchestrator@v1.0.0` — a
double application of IoC: skills drive sub-agent behavior, and skills drive
orchestrator routing.

**Verdict: Supported.**

---

### Gap Analysis

**Risk: AgentCore Memory adapter interface.**
The Strands SDK integration with AgentCore Memory has not been prototyped in this
environment. If the SDK requires a different session-manager protocol, the adapter
interface in `memory_adapter.py` may need adjustment.

*Mitigation:* Build the adapter as a thin shim in Phase 2.3. If AgentCore Memory
SDK surface is incompatible with Strands `session_manager`, fall back to
`S3SessionManager` for Phase 2.3 and revisit Memory integration as Phase 2.6.
The IoC validation stands regardless — session storage is infrastructure wiring,
not domain logic.

**Risk: Strands MCP Gateway tool resolution.**
The Strands `MCPClient` integration with AgentCore Gateway has not been prototyped.
If the Gateway's MCP protocol differs from what `MCPClient` expects, tool resolution
may fail at Phase 2.3.

*Mitigation:* Build a stub `get_gateway_tools` first (returns `@tool`-decorated
functions that call Lambdas directly via `lambda:invoke`). Validate the agent
behavior end-to-end, then swap for real Gateway resolution. The skill content and
agent shell are unaffected by which implementation of `get_gateway_tools` is used.

**Risk: AgentCore Control Plane `invoke_agent_runtime` from within another AgentCore Runtime.**
The dispatch pattern (supervisor AgentCore Runtime invoking sub-agent AgentCore
Runtime) requires IAM policy allowing `bedrock-agentcore:InvokeAgentRuntime` on
the sub-agent ARNs. Not a design gap — an IAM wiring note for Phase 2.4.

---

## Section 8 — Supporting Design Artifacts

### 8.1 DynamoDB Agent Registry — Extended Schema

Existing table `ai-platform-dev-agent-registry` is extended with discovery fields.
Each agent layer writes its entry during `terraform apply`.

```json
{
  "agent_id":          "hr-assistant-strands-dev",
  "agent_name":        "HR Assistant",
  "runtime_arn":       "arn:aws:bedrock-agentcore:us-east-2:096305373014:runtime/...",
  "domains":           ["hr.policy", "hr.escalation"],
  "available_skills":  ["hr/policy-lookup@v1.0.0",
                        "hr/escalation-procedure@v1.0.0"],
  "baseline_skills":   ["platform/agent-behavior@v1.0.0"],
  "tier":              "conversational",
  "enabled":           true,
  "owner_team":        "hr-platform",
  "model_arn":         "us.anthropic.claude-sonnet-4-6",
  "guardrail_id":      "...",
  "guardrail_version": "DRAFT",
  "prompt_vault_lambda_arn": "...",
  "updated_at":        "2026-04-20T00:00:00Z"
}
```

**Deprecated for Strands agents (retained for Phase 1 boto3 during transition):**
- `system_prompt_arn` — prompt is composed from SKILL.md files
- `knowledge_base_id` — KB access lives in `search_hr_documents` Lambda

**Orchestrator discovery logic:**

```python
# agents/orchestrator/container/app/discovery.py
import os
import boto3

_TABLE = os.environ["AGENT_REGISTRY_TABLE"]


def load_domain_map() -> dict[str, dict]:
    """Scan registry at startup; build domain → agent metadata map."""
    dynamodb = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"])
    table = dynamodb.Table(_TABLE)

    domain_map: dict[str, dict] = {}
    scan_kwargs = {"FilterExpression": "enabled = :t",
                   "ExpressionAttributeValues": {":t": True}}
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            for domain in item.get("domains", []):
                domain_map[domain] = {
                    "agent_id":         item["agent_id"],
                    "runtime_arn":      item["runtime_arn"],
                    "available_skills": item["available_skills"],
                    "baseline_skills":  item["baseline_skills"],
                }
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return domain_map
```

### 8.2 XML Composition Format

Composed system prompt structure:

```
{precedence preamble}

<skill name="platform/agent-behavior" version="v1.0.0">
{body of platform/agent-behavior}
</skill>

<skill name="hr/policy-lookup" version="v1.0.0">
{body of hr/policy-lookup}
</skill>
```

Claude 4.x models adhere to XML-tagged structure more reliably than bare markdown
section headers (per Anthropic prompt engineering guidance). XML attributes carry
skill identity — useful in traces and when debugging skill-attribution questions.

### 8.3 Skill Authoring Discipline

To minimize conflicts resolved by the precedence preamble, skill authors follow a
responsibility split:

**Baseline skills own HOW:**
- Citation format
- Confidence language
- Tone for sensitive conversations
- Response format defaults
- Hard-constraint safety rules (never speculate, never provide legal/medical advice)

**Domain skills own WHAT:**
- When and how to use domain-specific tools
- Domain-specific output structure
- Domain-specific examples
- Domain-specific hard constraints

Reviewers reject skills that cross into the other's territory. The precedence
preamble is a backstop, not a permit to overlap.

### 8.4 PII Middleware

Orchestrator container middleware runs `comprehend.detect_pii_entities` on every
inbound message before the Strands Agent is invoked. Returned entities drive an
offset-based redaction:

```python
# agents/orchestrator/container/app/middleware/pii.py
import os
import boto3

_comprehend = boto3.client("comprehend", region_name=os.environ["AWS_REGION"])


def detect_and_redact(text: str, language: str = "en") -> tuple[str, list[dict]]:
    """
    Returns (redacted_text, detected_entities).
    detected_entities is [{"Type": "SSN", "BeginOffset": 0, "EndOffset": 11, "Score": 0.99}, ...]
    """
    resp = _comprehend.detect_pii_entities(Text=text, LanguageCode=language)
    entities = resp.get("Entities", [])
    if not entities:
        return text, []

    # Sort by offset descending so substitutions don't shift earlier offsets.
    entities_sorted = sorted(entities, key=lambda e: e["BeginOffset"], reverse=True)
    redacted = text
    for e in entities_sorted:
        redacted = (
            redacted[:e["BeginOffset"]]
            + f"[REDACTED_{e['Type']}]"
            + redacted[e["EndOffset"]:]
        )
    return redacted, entities
```

Original text is included in the audit log record (encrypted at rest via the
CloudWatch Logs KMS key). Redacted text is what the Strands Agent sees.

### 8.5 Audit Logging

Application audit events emitted by the orchestrator container as structured JSON
to CloudWatch Logs:

```json
{
  "event":          "request_received",
  "session_id":     "session-abc123",
  "user_role":      "hr-employee",
  "pii_detected":   false,
  "pii_types":      [],
  "request_chars":  142,
  "timestamp":      "2026-04-20T10:00:00.123Z"
}
```

```json
{
  "event":           "response_sent",
  "session_id":      "session-abc123",
  "domain":          "hr.both",
  "agents_dispatched": 2,
  "sub_agent_skill_ids": [
    "hr/policy-lookup@v1.0.0",
    "hr/escalation-procedure@v1.0.0"
  ],
  "response_chars":  1340,
  "latency_ms":      4210,
  "timestamp":       "2026-04-20T10:00:04.333Z"
}
```

AgentCore Observability captures metrics, conversation flows, tool-usage patterns,
and error rates automatically — no explicit instrumentation required beyond the
container's own structured logs.

### 8.6 IAM Prefix Scoping for Skills Bucket

Each agent role's policy grants `s3:GetObject` only on the prefixes it needs:

```hcl
# agents/hr-assistant-strands/main.tf — agent execution role inline policy
data "aws_iam_policy_document" "skills_read" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [
      "${data.terraform_remote_state.platform.outputs.skills_bucket_arn}/skills/platform/*",
      "${data.terraform_remote_state.platform.outputs.skills_bucket_arn}/skills/hr/*",
    ]
  }
}
```

Orchestrator policy is stricter (only `skills/platform/*`):

```hcl
# agents/orchestrator/main.tf
data "aws_iam_policy_document" "skills_read" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [
      "${data.terraform_remote_state.platform.outputs.skills_bucket_arn}/skills/platform/*",
    ]
  }
}
```

The prefix list is derived from the agent's `domains` variable — adding a new
domain to an agent extends the IAM grant automatically.

### 8.7 Skill Publish Workflow

Until Phase 2.5 defines tooling more formally:

1. Author edits SKILL.md locally.
2. Validation: frontmatter schema check (all required fields, no unknown keys),
   YAML parseability, model/guardrail consistency if composed with known peers.
3. Verify target key doesn't already exist: `aws s3api head-object --bucket ...
   --key skills/<path>/<version>/SKILL.md` must return 404.
4. PR review by the owning team (HR for `hr/*`, Platform for `platform/*`).
5. On merge: CI pipeline publishes to S3 with `--cache-control max-age=0` (not relevant
   to S3 but preserved for any CDN layer added later).

For staging/prod (Object Lock enabled), step 3 is enforced by IAM (new-key PUT is
allowed; overwrite fails). For dev (no Object Lock), step 3 is a CI pre-check.

### 8.8 Environment Variable Summary

**HR Assistant Strands sub-agent container:**
```
AWS_REGION=us-east-2
SKILLS_ENABLED=true
SKILLS_BUCKET=ai-platform-dev-skills
GATEWAY_ENDPOINT=<platform MCP Gateway>
GUARDRAIL_ID=<hr-assistant-guardrail>
GUARDRAIL_VERSION=DRAFT
AGENTCORE_MEMORY_ID=<shared memory resource>
AGENT_REGISTRY_TABLE=ai-platform-dev-agent-registry
# Legacy during transition:
BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-6
PROMPT_VAULT_BUCKET=<existing>
```

**Orchestrator container:**
```
AWS_REGION=us-east-2
SKILLS_BUCKET=ai-platform-dev-skills
GUARDRAIL_ID=<platform-guardrail>
GUARDRAIL_VERSION=DRAFT
AGENTCORE_MEMORY_ID=<shared memory resource>
AGENT_REGISTRY_TABLE=ai-platform-dev-agent-registry
RATE_LIMIT_TABLE=ai-platform-dev-rate-limit  # new, per Phase 2.4
```
