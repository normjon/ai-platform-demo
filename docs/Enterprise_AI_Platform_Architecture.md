# Enterprise AI Platform
## Architecture & Rollout Strategy

AWS Bedrock | AgentCore | Glean | Claude Code

*A comprehensive reference architecture for secure, governed, scalable enterprise AI*

Version 1.0 | March 2026

**Classification: Confidential | Internal Distribution Only**

# Table of Contents

---

# 1 Executive Overview

This document defines the reference architecture for the enterprise AI platform. It covers the foundational infrastructure layer, the agent runtime and operational layer, the enterprise knowledge layer, the developer tooling strategy, and the AWS organisational and governance structure that governs everything. It is intended as the authoritative technical reference for platform architects, engineering leads, security, and compliance stakeholders.

The platform is built on three primary technology pillars — AWS Bedrock, Amazon Bedrock AgentCore, and Glean — each addressing a distinct and complementary layer of the enterprise AI capability stack. Underlying the platform is a deliberate AWS organisational structure that enforces governance, isolates environments, centralises billing, and scales cleanly as the platform matures.

## 1.1 Strategic Rationale

The enterprise AI platform is a foundational infrastructure decision, not a point solution. The technology choices made here will underpin AI capability across the organisation for the next several years. The selection criteria are not which platform produces the most impressive demonstration, but which platform can be governed, operated, secured, and scaled reliably over a multi-year horizon without accumulating unacceptable technical or vendor risk.

| **Principle**                         | **How the Architecture Delivers It**                                                                                                                                                                                                                                        |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Lowest risk foundation**            | AWS Bedrock is a production-hardened service trusted by over 100,000 organisations globally, in general availability since September 2023 with Anthropic as a launch partner. The technology risk is known, bounded, and backed by AWS SLAs and support.                    |
| **Governance without friction**       | AgentCore's manifest-driven configuration enforces compliance at generation time rather than review time. Claude Code translates engineer intent into policy-compliant scaffolds automatically. Governance is invisible to the builder because it is encoded in the system. |
| **Adoption as a first-class concern** | The platform bottleneck — where knowledge concentrates in the team that built the platform — is addressed structurally through Claude Code, a self-improving documentation system, and an automated PR review process. Adoption is designed in, not retrofitted.            |
| **Single vendor relationship**        | All infrastructure, model access, developer tooling, and billing flow through AWS. No separate Anthropic account, no separate API keys, no parallel enterprise agreements. One contract, one bill, one governance model.                                                    |
| **Migration alignment**               | As an organisation migrating from Azure to AWS, the AI platform is the leading edge of the AWS migration. Every dollar invested in this platform is invested in the infrastructure the organisation is moving toward, not away from.                                        |

---

# 2 Platform Architecture Overview

The platform architecture is organised into seven layers. Each layer has a clearly defined responsibility, a set of AWS services that implement it, and clean interfaces to the layers above and below. No layer reaches across its boundaries — dependencies are always downward, never lateral or upward.

## 2.1 Architecture Layer Model

**Layer 7 — Developer Tooling**  
Claude Code | CLAUDE.md | Self-Improving Documentation | PR Review Automation

**Layer 6 — Agent Interaction**  
CLI | Web | API | Slack | Scheduled Headless Execution

**Layer 5 — Agent Runtime**  
AgentCore Runtime | Memory | Identity | Observability | MCP Gateway

**Layer 4 — Knowledge & Search**  
Bedrock Knowledge Bases | OpenSearch Serverless | Glean Enterprise Search (MCP Tool)

**Layer 3 — Foundation Models**  
Amazon Bedrock | Claude Sonnet / Haiku | Titan Embeddings | Guardrails

**Layer 2 — Data & Integration**  
S3 | Glue ETL | EventBridge | Step Functions | DynamoDB | Lambda

**Layer 1 — AWS Organisational Foundation**  
AWS Organizations | Control Tower | IAM Identity Centre | SCPs | CloudTrail

## 2.2 The Three Technology Pillars

| **Pillar**      | **Purpose**                                                                                                                                                      | **Primary Services**                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| **AWS Bedrock** | Managed AI foundation layer. Secure, governed access to foundation models. Knowledge Base management, Guardrails, fine-tuning, and compliance framework.         | Bedrock API, Knowledge Bases, Guardrails, Titan Embeddings, Prompt Management, Model Evaluation |
| **AgentCore**   | Agent operational runtime. Lifecycle management, memory, tool access governance, identity controls, and observability for production agents.                     | AgentCore Runtime, Memory, MCP Gateway, Identity, Observability, Agent Registry                 |
| **Glean**       | Enterprise knowledge layer. Permissions-aware search across all organisational systems indexed from 100+ connectors. Exposed as an MCP tool through the Gateway. | Glean Enterprise Search, Enterprise Graph, MCP Server, Glean Protect                            |

---

# 3 AWS Organisational Structure

The AWS organisational structure is the most foundational architectural decision in this document. It is set before any workload is deployed, and retrofitting it after the fact is costly and disruptive. The structure defined here is designed to serve the AI platform today and the full cloud migration as it progresses.

## 3.1 AWS Organizations Hierarchy

The management account sits at the root of the organisation and is a pure governance and billing account. It contains no workloads. Its sole purpose is to own the organisational hierarchy, consolidated billing, Service Control Policies, and the AWS Control Tower landing zone. Keeping it clean of workloads ensures that no application incident can affect the governance layer.

| **Account / OU**                                     | **Purpose and Contents**                                                                                                                                                                                                                                                  |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Management Account (Root)**                        | Governance and billing only. Owns AWS Organizations, consolidated billing, SCPs, Control Tower, and AWS Config aggregation. Zero workloads.                                                                                                                               |
| **Shared Services OU**                               | Platform infrastructure shared across all workload accounts. Contains the shared services account hosting the platform documentation repository, CodePipeline definitions, centralised KMS keys, CloudTrail log archive, Security Hub aggregation, and Grafana workspace. |
| **Production OU**                                    | All production workload accounts. SCPs enforce the strictest governance posture — approved regions only, CloudTrail immutable, deletion protection, no public endpoints, approved Bedrock model ARNs only.                                                                |
| **Production \> AI Platform Sub-OU**                 | Production AI workload accounts. Inherits Production OU SCPs plus AI-specific controls. Contains the External Production Account and Internal Production Account.                                                                                                         |
| **Production \> AI Platform \> External Production** | User-facing production agents. WAF, aggressive rate limiting, strict guardrail configurations, Cognito user pool authentication. Highest security posture.                                                                                                                |
| **Production \> AI Platform \> Internal Production** | Internal operational agents. IAM machine-to-machine authentication, broader tool access within ToolPolicy bounds, tuned for internal trust model.                                                                                                                         |
| **Non-Production OU**                                | All staging and development accounts. Relaxed SCPs relative to production while maintaining non-negotiable controls — CloudTrail always on, approved regions, no public S3 buckets.                                                                                       |
| **Non-Production \> Staging Account**                | Pre-production environment shared across agent types. Full pipeline validation runs here before production promotion. Connects to sandbox versions of backend systems.                                                                                                    |
| **Non-Production \> Development Account**            | Engineering development and iteration. Loosest controls, lowest cost thresholds. Never connects to production systems or contains real data.                                                                                                                              |
| **Sandbox OU**                                       | Free experimentation accounts. Hard budget cap as the primary control. No real data, no production system connectivity enforced by SCP. Account vending machine provisioned via Control Tower.                                                                            |

## 3.2 Service Control Policies

SCPs define the maximum permissions available to any principal in any account within an OU, regardless of what IAM policies within that account permit. They are the ultimate governance enforcement layer and cannot be overridden from within a member account.

| **SCP**                           | **Applied At**                                                                                                                                          |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Bedrock model ARN restriction** | AI Platform Sub-OU. Only approved model ARNs can be invoked. Prevents use of unapproved or overly capable models regardless of local IAM configuration. |
| **Data residency enforcement**    | Production OU. Resources can only be created in approved AWS regions. Satisfies data residency requirements without per-account configuration.          |
| **CloudTrail immutability**       | All OUs. CloudTrail cannot be disabled, log files cannot be deleted, and log validation cannot be turned off. The audit trail is non-negotiable.        |
| **S3 public access block**        | All OUs. All S3 buckets must have public access blocked. No exceptions at the account level.                                                            |
| **Encryption requirement**        | Production OU. All storage resources must use KMS encryption. Unencrypted resources cannot be created.                                                  |
| **GuardDuty and Security Hub**    | All OUs. Cannot be disabled in any member account. Security findings aggregate to the shared services account Security Hub.                             |
| **Cost controls**                 | Non-Production OU. Restricts provisioning of high-cost instance types and services not required for development workloads.                              |

## 3.3 Centralised Identity — IAM Identity Centre

IAM Identity Centre is the single identity plane for all human access across all AWS accounts. Engineers authenticate once through the corporate SSO — Azure AD, Okta, or equivalent — receive short-lived session tokens, and those tokens govern their access across every account they are authorised to reach. There are no IAM users, no long-lived access keys, and no per-account credential management.

| **Permission Set**   | **Access Scope**                                                                                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **PlatformAdmin**    | Full access across all AI platform accounts. Restricted to the platform engineering team leads. MFA required.                                               |
| **PlatformEngineer** | Read/write access to development and staging accounts. Read-only access to production accounts. Standard platform engineering team members.                 |
| **AgentDeveloper**   | Read/write access to development account. Read-only access to staging. No production access. Standard application engineering team members building agents. |
| **AIQualityReview**  | Read access to Prompt Vault S3 buckets and DynamoDB quality tables across all accounts. Write access to annotation records. Quality and safety review team. |
| **ReadOnly**         | Read-only access across all accounts for audit, compliance, and security review purposes.                                                                   |
| **BillingAdmin**     | Access to Cost Explorer, Budgets, and billing console in the management account. Finance team.                                                              |

---

# 4 Amazon Bedrock — Foundation Layer

Amazon Bedrock is the managed AI foundation that all platform capabilities are built on. It provides secure, IAM-governed access to foundation models through a single API, without any infrastructure management. All model invocations — whether from production agents, developer tooling, headless automation, or the Claude Code on-ramp — are routed through Bedrock. There is no direct Anthropic API access in this architecture.

## 4.1 Model Access and Governance

Model access is controlled at two levels. IAM policies in each account define which roles can invoke the Bedrock API at all. SCPs at the AI Platform Sub-OU level restrict which model ARNs can be invoked, regardless of what IAM policies permit. Together these ensure that only approved models are used in production and that a misconfigured IAM policy cannot enable unapproved model access.

| **Model**                                                          | **Approved Use Cases**                                                                                                                                                                                                                                                                                                                                                                            |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Claude Sonnet 4.x (claude-sonnet-4-6) — Production and Staging** | Primary reasoning model for production and staging agents. Complex multi-step reasoning, document analysis, structured output generation, supervisor agent orchestration. The identical model ARN must be used in both staging and production — staging fidelity depends on this constraint being enforced without exception.                                                                     |
| **Claude Haiku 4.x (claude-haiku-4-5) — Production and Staging**   | High-volume, cost-sensitive tasks. LLM-as-Judge quality scoring, document classification, metadata extraction, quick-turnaround tool responses. Same version constraint applies — staging and production ARNs must match exactly.                                                                                                                                                                 |
| **Titan Embeddings V2 — All environments**                         | Vector embedding generation for Knowledge Base document ingestion. All semantic similarity retrieval in OpenSearch Serverless.                                                                                                                                                                                                                                                                    |
| **Claude Sonnet or Haiku (development only)**                      | Engineering iteration, prompt development, golden dataset generation. Development is the only environment where a different model version may be used — specifically for evaluating a candidate model version before committing to a platform-wide upgrade. Any version divergence from production must be explicitly declared in the development manifest and reviewed before staging promotion. |

**Model ARN as a Promotable Artifact**  
The model ARN declared in an agent manifest is treated as a versioned, promotable artifact that travels through the promotion pipeline alongside the manifest configuration it belongs to. When a new model version is adopted platform-wide, the ARN update is a manifest change that flows through development, staging validation, and canary rollout before reaching full production. The manifest validated in staging and the manifest running in production are always identical. There is no mechanism by which a different model ARN can reach production without first being validated in staging.

## 4.2 Knowledge Layer Strategy — Glean as Default

Glean is the default knowledge layer for the enterprise AI platform. When an agent needs to retrieve organisational knowledge, the starting assumption is that Glean provides it. Glean indexes knowledge as it is created across 100+ connected systems — automatically, in real time, with permission-aware retrieval — without any ingestion pipeline to build or maintain. For the vast majority of knowledge retrieval use cases, Glean is the right tool and Bedrock Knowledge Bases are not necessary.

Bedrock Knowledge Bases are the deliberate choice for a specific and well-defined category of content — curated, governed, relatively static reference material where the ingestion pipeline itself is part of the governance and quality posture. The decision to use a Bedrock Knowledge Base rather than relying on Glean should be explicit and justified.

### When to use Glean (default)

| **Content Type**                  | **Why Glean Is Appropriate**                                                                                                                                  |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Organisational communications** | Slack conversations, email threads, meeting notes — living knowledge that Glean indexes automatically from connected systems. No ingestion pipeline required. |
| **Collaborative work products**   | Confluence pages, Notion docs, Google Drive files, Jira tickets — content that evolves continuously and benefits from Glean's real-time connector sync.       |
| **Institutional knowledge**       | Decisions made in documents, expertise encoded in who has written what, relationships between people and topics captured in the Enterprise Graph.             |
| **Code and technical content**    | GitHub repositories, code comments, PR discussions — Glean's code search understands structure and dependencies, not just text.                               |
| **Cross-system research**         | Any query that benefits from searching across multiple source systems simultaneously with a unified relevance model.                                          |

### When to use Bedrock Knowledge Bases (deliberate choice)

| **Condition**                                                | **Rationale**                                                                                                                                                                                                                       |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Content requires controlled ingestion with quality gates** | Policy documents, compliance materials, and technical standards that must pass PII detection, quality scoring, and classification tagging before agents can retrieve them. The ingestion pipeline is itself a governance control.   |
| **Deterministic retrieval is required for testing**          | Agents whose behaviour must be validated against a fixed, known knowledge state as part of the promotion pipeline. Bedrock Knowledge Bases provide a stable, versioned index that golden dataset tests can be reliably run against. |
| **Content is not in any Glean-connected system**             | Source material that exists outside Glean's connector ecosystem and where building a Glean connector is not justified. S3-based ingestion into a Bedrock Knowledge Base is the appropriate alternative.                             |
| **Specialised chunking strategy is required**                | Highly structured documents — legal contracts, financial statements, technical specifications — that require domain-specific chunking logic not supported by Glean's indexing approach.                                             |
| **Data classification ceiling requires complete isolation**  | Confidential-tier content that must never leave a tightly controlled ingestion and retrieval path with dedicated KMS keys, isolated OpenSearch indexes, and restricted access policies.                                             |

### Active Bedrock Knowledge Bases

The following Knowledge Bases are maintained under the Bedrock ingestion pipeline because they meet one or more of the deliberate-choice conditions above. All other organisational knowledge is served through Glean.

| **Knowledge Base**            | **Contents**                                                                                                                                                                    | **Data Classification** |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| **HR Policies KB**            | Employee handbook, leave policies, benefits documentation, compliance training materials. Requires PII gate and classification tagging — Glean connector alone is insufficient. | Internal                |
| **IT Procedures KB**          | Service desk runbooks, system access procedures, infrastructure standards, incident response guides. Requires versioned, testable retrieval for agent quality validation.       | Internal                |
| **Platform Documentation KB** | Agent manifest schema, pipeline templates, governance policies, MCP tool catalogue. Requires deterministic retrieval for Claude Code and scheduled validation agents.           | Internal                |
| **Finance Policies KB**       | Expense policies, procurement procedures, financial controls documentation. Confidential ceiling requires isolated ingestion path and dedicated KMS key.                        | Confidential            |
| **Product Knowledge KB**      | Product specifications, technical documentation, release notes, API references. Structured content requiring hierarchical chunking strategy not suited to Glean indexing.       | Internal                |

**Security Note on Glean Permission Enforcement**  
Glean's permission model filters results against the calling user's actual permissions in each source system. This is enforced by Glean at query time and is a genuine security control — not a best-effort filter. However, Glean's security guarantee is dependent on the accuracy of permissions in the source systems it indexes. A source system with misconfigured permissions will expose that misconfiguration through Glean search results. Regular permission audits of connected source systems are a prerequisite for relying on Glean as the default knowledge layer.

## 4.3 Document Ingestion Pipeline

The document ingestion pipeline is the process by which raw source documents become searchable knowledge in Bedrock Knowledge Bases. It is an event-driven pipeline that runs automatically when documents are added or updated in source systems.

| **Source Document lands in S3** | **Glue ETL cleans and tags** | **EventBridge fires** | **Lambda routes by classification** | **Bedrock StartIngestionJob** | **Chunk \> Embed \> Index** | **Smoke test validates** | **Agent queries updated KB** |
| --------------------------------- | ------------------------------ | ----------------------- | ------------------------------------- | ------------------------------- | ----------------------------- | -------------------------- | ------------------------------ |

AWS Glue handles the upstream preparation — format conversion to clean text, PII detection and redaction through Amazon Macie, deduplication, quality scoring, and governance metadata tagging including data classification. The processed document lands in the processed S3 bucket with classification metadata attached. EventBridge fires on the S3 PutObject event, triggering a Lambda that reads the classification tag, determines the target Knowledge Base, and calls the Bedrock StartIngestionJob API. Bedrock then handles chunking, embedding via Titan Embeddings V2, and vector indexing into OpenSearch Serverless natively — no custom compute required for this stage.

## 4.3.1 Ingestion Pipeline Observability

Pipeline observability is a first-class operational requirement. Agents depend on Knowledge Bases being current and accurate. Silent pipeline failures — a Glue job that stops running, an ingestion job that consistently fails, a smoke test that passes despite degraded retrieval quality — are invisible until an agent starts returning stale or incorrect answers. The following monitoring baseline must be active before any Knowledge Base is used in production.

### AWS Pipeline Metrics and Alerting

| **Metric**                                   | **Alert Condition**                                                                                                                                                                                           |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Glue job success rate**                    | Alert if success rate drops below 95% over any 24-hour window. Investigate immediately if any job fails more than twice consecutively.                                                                        |
| **Glue job duration trend**                  | Alert if average job duration increases more than 50% week-over-week. Signals growing data volume or processing inefficiency requiring capacity review.                                                       |
| **Ingestion orchestrator Lambda error rate** | Alert if error rate exceeds 1% over any 1-hour window. Lambda errors mean documents are not reaching the Bedrock ingestion API.                                                                               |
| **Bedrock StartIngestionJob failure rate**   | Alert on any ingestion job failure. Failed jobs are retried up to three times with exponential backoff. After three failures the document is routed to the dead letter queue and a high-priority alert fires. |
| **EventBridge dead letter queue depth**      | Alert if DLQ depth exceeds zero. Any message in the DLQ represents a document that could not be routed to the correct Knowledge Base and requires manual investigation.                                       |
| **Post-ingestion smoke test pass rate**      | Alert if smoke test pass rate drops below 100% for any Knowledge Base in any 24-hour window. A failed smoke test means a document was indexed but is not retrievable — the index may be corrupted.            |
| **OpenSearch indexing error rate**           | Alert on any indexing errors. Errors at this stage mean chunks were generated and embedded but could not be written to the index.                                                                             |

### Knowledge Base Freshness Monitoring

Pipeline success metrics tell you whether individual ingestion jobs completed. They do not tell you whether the Knowledge Base as a whole is current. A document updated in a source system but never re-ingested due to a silent event trigger failure is an invisible staleness problem that operational metrics alone will not surface.

| **Freshness Signal**                           | **Implementation**                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Last successful ingestion timestamp per KB** | DynamoDB record updated on every successful ingestion job completion. CloudWatch alarm fires if any Knowledge Base has not received a successful ingestion event within its expected cadence — 24 hours for daily-synced KBs, 7 days for weekly-synced KBs.                                                                   |
| **Document age distribution**                  | Athena query over the Prompt Vault metadata tracks the age of the most recently ingested version of each document category. Dashboard alert if any category has documents older than the source system update frequency warrants.                                                                                             |
| **Scheduled validation agent**                 | Weekly headless Claude Code agent reads a sample of Knowledge Base documents and cross-references their content against the source system versions. Discrepancies between KB content and source content generate a high-priority staleness PR. This is the active verification layer on top of the passive metric monitoring. |

### Glean Connector Health and MCP Gateway Observability

Glean's observability surface is different from the AWS ingestion pipeline because the indexing infrastructure is Glean-managed rather than platform-managed. Observability of Glean operates at two levels — the connector health within Glean's admin console, and the MCP Gateway metrics that reflect how Glean is performing from the platform's perspective.

| **Observability Layer**                       | **What to Monitor**                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Glean connector health (admin console)**    | Each source system connector has a sync status, last successful sync timestamp, and error log in the Glean admin console. The platform team reviews connector health weekly as part of the standard operational rhythm. Connectors with authentication errors, sync failures, or falling behind their sync schedule are escalated immediately — a connector that stops syncing means agents lose access to that source system's knowledge without any platform-side alert firing. |
| **MCP Gateway Glean tool invocation metrics** | The Gateway logs every Glean tool call: query text, response time, result count, calling agent identity, and HTTP status code. CloudWatch alarms on sustained response time increases above the P95 baseline, result count drops below expected ranges for standard query types, and error rate increases above 1% over any 30-minute window. These signals detect Glean degradation from the platform's perspective without requiring access to Glean's internal telemetry.      |
| **Glean result quality signals**              | The LLM-as-Judge quality pipeline tracks groundedness scores per agent. A sustained decline in groundedness for agents that rely heavily on Glean as their knowledge source is an indirect signal that Glean result quality has degraded — either through connector staleness, index drift, or relevance model changes. This signal complements the operational metrics with a quality-layer perspective.                                                                         |

## 4.4 Index Versioning

For incremental document additions, Bedrock updates the active index directly and a smoke test validates the addition post-ingestion. For configuration changes that require a full rebuild — changing the chunking strategy or embedding model — a versioned index pattern is used. A new OpenSearch index version is built in parallel while the current index continues serving queries. The alias cutover is a single atomic metadata operation once the new index passes the validation suite. The old index is retained for a seven-day rollback window before deletion.

---

# 5 AgentCore — Agent Runtime Layer

Amazon Bedrock AgentCore is the operational runtime that transforms foundation model capability into production-grade AI agents. It reached general availability on October 13, 2025. AgentCore provides the complete lifecycle infrastructure that agents require — session isolation, memory management, governed tool access, identity controls, and end-to-end observability — without any infrastructure management overhead.

## 5.1 AgentCore Endpoint Topology

AgentCore endpoints are logical access boundaries that segment agents by security posture, trust model, and traffic characteristics. Endpoint topology follows the AWS account structure — each production account has its own AgentCore endpoint configuration with appropriate IAM boundaries, VPC placement, and API Gateway configuration.

| **Endpoint**            | **Configuration**                                                                                                                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **External Production** | User-facing agents. WAF enabled, aggressive rate limiting (100 rpm per user), strict guardrail configuration, Cognito user pool authentication, all traffic logged. Hosted in the External Production AWS account. |
| **Internal Production** | Internal operational agents. IAM machine-to-machine authentication, moderate rate limiting, guardrail configuration tuned for internal trust model. Hosted in the Internal Production AWS account.                 |
| **Staging**             | Pre-production validation for both agent types. Identical configuration to production endpoints for staging fidelity. Connects to sandbox backend systems via staging MCP Gateway.                                 |
| **Development**         | Engineering iteration. Relaxed rate limits, verbose logging, no WAF. Connects to mock or sandbox tool endpoints. Fastest iteration cycle.                                                                          |

## 5.2 The Agent Manifest

Every agent deployed on the platform is defined by a manifest — a structured JSON configuration that declares every aspect of the agent's identity, capability, and governance posture. The manifest is the governance contract between the agent and the platform. AgentCore enforces it at runtime. Claude Code generates it during onboarding.

```json
{
"agentId": "hr-assistant-v2",
"displayName": "HR Assistant",
"modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
"systemPromptArn": "arn:aws:bedrock:us-east-1:ACCOUNT:prompt/hr-assistant-system-prompt",
"knowledgeBaseId": "kb-hr-policies-current",
"memoryConfig": {
"sessionTtlHours": 24,
"longTermMemoryEnabled": true,
"longTermRetentionDays": 365
},
"toolPolicy": {
"allowedTools": ["glean-search", "hr-system-lookup", "calendar-read"],
"deniedTools": ["hr-system-write", "payroll-access"]
},
"guardrailId": "gr-standard-internal",
"dataClassificationCeiling": "INTERNAL",
"qualitySla": { "groundingScoreMin": 0.75, "responseLatencyP95Ms": 3000 },
"costBudget": { "monthlyUsdLimit": 500, "alertThresholdPct": 80 }
}
```

## 5.3 Memory Architecture

| **Memory Tier**                               | **Implementation and Scope**                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Session Memory (DynamoDB)**                 | Conversation continuity within a single session. Stored in DynamoDB with 24-hour TTL. Single-digit millisecond read/write latency on the critical path. Sliding window compression preserves recent turns verbatim and older turns as a summary paragraph. Session ID persisted by the calling client for multi-turn continuity.                                         |
| **Long-Term Memory (OpenSearch Serverless)**  | Durable facts extracted from interactions — user preferences, decisions, project context, organisational knowledge. Persists for the retention period declared in the agent manifest. Retrieved via semantic similarity search at session start and injected into context window. Primary cost driver — selectively enabled per agent type based on value justification. |
| **Shared Memory (Step Functions + DynamoDB)** | Multi-agent workflow workspace. Initialised by supervisor agent with a unique workflow ID. Sub-agents read and write to typed sections of the workspace. Version-locked writes prevent concurrent update conflicts. Archived to S3 on workflow completion for audit and training data purposes.                                                                          |

## 5.4 MCP Gateway and Tool Ecosystem

The MCP Gateway is the governed interface between agents and the tools and systems they can invoke. It enforces the ToolPolicy declared in each agent's manifest, validates every tool call before execution, and provides the unified observability surface for all tool invocations regardless of what system they call.

| **Tool Category**          | **Tools**                                                                              | **Gateway**                           |
| ---------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------- |
| **Enterprise Search**      | Glean Search (semantic + structured), Glean Expert Lookup, Glean Code Search           | Standard MCP Gateway                  |
| **HR Systems**             | HRIS employee lookup, Leave balance query, Benefits information, Org chart navigation  | Standard MCP Gateway                  |
| **IT Systems**             | ServiceNow ticket creation/query, Asset lookup, Access request status, Incident search | Standard MCP Gateway                  |
| **Productivity**           | Calendar read, Email summary, Confluence page read, Jira ticket query                  | Standard MCP Gateway                  |
| **Platform Tools**         | Documentation search, Agent registry query, Quality metrics read, Prompt Vault read    | Standard MCP Gateway                  |
| **Finance Systems**        | Expense policy lookup, Budget query, PO status check                                   | Restricted MCP Gateway (Confidential) |
| **Workflow Orchestration** | Step Functions workflow init, task completion, exception handling, history query       | Standard MCP Gateway                  |

## 5.5 Deployment and Promotion Pipeline

| **Manifest committed to repo** | **Claude Code validation** | **Dev deployment** | **Automated test suite** | **Staging promotion** | **Quality gates** | **Production canary 5%** | **Full production rollout** |
| -------------------------------- | ---------------------------- | -------------------- | -------------------------- | ----------------------- | ------------------- | -------------------------- | ----------------------------- |

All agent deployments flow through a CodePipeline promotion pipeline. No manual deployment to production is permitted. The canary deployment pattern uses AgentCore's weighted alias routing — 5% traffic to the new version for 24 hours, expanding to 25%, 50%, and 100% with quality metric checkpoints at each stage. Automated rollback triggers if grounding score drops more than 5%, latency increases more than 20%, or user feedback thumbs-down rate increases more than 30%.

---

# 6 Glean — Enterprise Knowledge Layer

Glean provides the enterprise knowledge layer that Bedrock Knowledge Bases are not designed to replace. Where Bedrock Knowledge Bases hold curated, structured, deliberately-ingested reference content, Glean indexes the living organisational knowledge of the enterprise — the conversations, decisions, work-in-progress, and collective institutional memory distributed across every SaaS application your teams work in.

## 6.1 What Glean Provides

| **Capability**              | **Description**                                                                                                                                                                                                                                                                                        |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Enterprise Search**       | Semantic and structured search across all indexed organisational content. Understands intent rather than matching keywords. Returns permission-scoped results based on the calling user's identity.                                                                                                    |
| **Enterprise Graph**        | Maps relationships between people, documents, systems, and knowledge across the organisation. Enables queries like 'who is the expert on this topic' or 'what decisions were made about this project' that require understanding of organisational context, not just document content.                 |
| **100+ Native Connectors**  | Pre-built integrations for Slack, Confluence, Jira, GitHub, Google Drive, Microsoft 365, Salesforce, Zendesk, and 90+ more. Each connector indexes both content and metadata — who created it, when, who has access, how it relates to other content.                                                  |
| **Permissions Enforcement** | Every search result is filtered against the calling user's actual permissions in the source system. An agent calling Glean on behalf of a user can only surface content that user is authorised to see. This is enforced by Glean, not by the platform. Data never leaves Glean's permission boundary. |
| **Glean Protect**           | Multi-layer security suite covering data governance, agent behaviour controls, and runtime action authorisation. Ensures agents operating through Glean stay within defined boundaries.                                                                                                                |

## 6.2 Glean as an MCP Tool

Glean is registered in the MCP Gateway as a set of named tools. From AgentCore's perspective, Glean is just another governed tool endpoint — the agent declares it in its ToolPolicy, the Gateway validates the tool call, executes it, and returns the result. The agent has no awareness of Glean's internal architecture. It invokes a tool, receives structured results, and incorporates them into its reasoning.

| **Tool Name**              | **Description**                                                                                                                                                                                                                                          |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **glean-search**           | General semantic search across all indexed enterprise content within the calling user's permission scope. Takes a natural language query and optional filters (source system, date range, content type). Returns ranked results with source attribution. |
| **glean-expert-lookup**    | Identifies subject matter experts for a given topic based on the Enterprise Graph's understanding of who has created, discussed, or been referenced in relation to that topic.                                                                           |
| **glean-code-search**      | Semantic search specifically over code repositories. Understands code structure, function signatures, and dependencies rather than just treating code as text.                                                                                           |
| **glean-document-summary** | Retrieves and summarises a specific document by URL or identifier. Used when the agent needs the full content of a specific document rather than search results across many documents.                                                                   |

## 6.3 The Complementary Knowledge Model

**Bedrock Knowledge Bases + Glean — The Complete Knowledge Stack**  
Bedrock Knowledge Bases answer the question: what does the platform know from authoritative, curated, governed reference content? Glean answers the question: what does the organisation know from the collective intelligence embedded in its communications, decisions, and work products? Together they give agents access to both the official and the institutional knowledge of the enterprise. Neither is sufficient alone. An HR agent that can retrieve the leave policy from the Knowledge Base but cannot find the conversation where the exception was approved has an incomplete picture. An agent with access to both has the complete one.

---

# 7 Developer Tooling — Claude Code

Claude Code is the primary interface through which engineering teams interact with the AI platform. It is the mechanism by which the platform bottleneck is resolved — by encoding platform knowledge in a form that Claude Code can read and act on, that knowledge becomes available to every engineer simultaneously without any marginal cost per engineer and without any platform team availability required.

## 7.1 Claude Code and Bedrock

Claude Code is configured at the enterprise level to use Bedrock as its backend rather than the default Anthropic API endpoint. This means all Claude Code usage by engineering teams flows through your AWS account, is governed by IAM, is billed through consolidated AWS billing, and is subject to the same SCPs and cost controls as every other Bedrock invocation on the platform. There is no separate Anthropic enterprise agreement, no separate API key management, and no separate billing relationship.

```text
<strong>Credential Model for Claude Code</strong>
Engineers authenticate through corporate SSO via IAM Identity Centre.
IAM Identity Centre issues short-lived session tokens valid for the work session.
Claude Code uses those session tokens to sign Bedrock API calls using AWS Signature Version 4.
No long-lived credentials, no API keys, no per-engineer Anthropic accounts.
All Claude Code invocations appear in CloudTrail tagged to the engineer's IAM identity.
Cost attribution by team is automatic through resource tagging.
```

## 7.2 The Platform Knowledge Base

The platform knowledge base is the versioned documentation repository that Claude Code reads at the start of every session. It is the encoded intelligence of the platform team — every decision, every pattern, every constraint, every governance requirement — made explicit enough that a code agent can act on it precisely without clarification.

```bash
platform-docs/
CLAUDE.md # Root Claude Code instructions
/manifest/
schema.json # Complete agent manifest JSON schema
field-reference.md # Every field with valid values and constraints
examples/ # Complete manifest examples per agent type
/system-prompts/
template-structure.md # Required sections and purpose
patterns/ # Pattern library for common agent types
anti-patterns.md # Known patterns that cause quality/safety issues
/pipelines/
agent-promotion.md # dev > staging > production guide
quality-gates.md # Gate definitions and pass criteria
templates/ # CodePipeline YAML templates per classification
/knowledge-base/
ingestion-guide.md # How to add documents to a KB
chunking-strategies.md # Strategy selection guide
/mcp-tools/
tool-catalogue.md # All tools: schema, usage, rate limits
glean-integration.md # Glean tool usage patterns and examples
/governance/
policies.md # Complete governance policy catalogue
classification-guide.md # Data classification rules and implications
/observability/
metrics-reference.md # All platform metrics and thresholds
alarm-templates/ # CloudWatch alarm definitions per tier
/quick-start/
getting-started.md # First agent in under a day
CLAUDE.md # Team-level CLAUDE.md template
```

## 7.3 The Self-Improving Documentation Loop

The documentation gap resolution instruction in CLAUDE.md is the mechanism that keeps the knowledge base current without requiring deliberate documentation effort from engineering teams. When Claude Code cannot determine something it needs to know from the existing documentation, it surfaces the gap explicitly, resolves it with the engineer, and generates a documentation PR using the standard template. The PR goes through the same Claude Code review process as all other platform PRs.

| **Engineer builds agent** | **Claude hits gap** | **Gap surfaced explicitly** | **Engineer resolves** | **PR auto-generated** | **Claude reviews PR** | **Test case executed** | **Merged and live** |
| --------------------------- | --------------------- | ----------------------------- | ----------------------- | ----------------------- | ----------------------- | ------------------------ | --------------------- |

Every onboarding cycle makes the next one smoother. Gap PR rate in foundational sections declines as the knowledge base matures. New teams inherit everything learned from every previous team. The platform gets easier to use the more it is used — the opposite of typical internal platform entropy.

## 7.4 Scheduled Validation Agents

The MCP tool catalogue and Knowledge Base configurations are continuously validated by scheduled headless Claude Code agents that run on a defined cadence. These agents proactively verify that documented tool schemas still match live API schemas, that authentication credentials remain valid, that Knowledge Base source connections are healthy, and that embedding model configurations have not drifted from the live OpenSearch index configuration. Schema drift, authentication failures, and configuration drift are surfaced as high-priority PRs before they cause production agent failures.

---

# 8 Security and Governance

## 8.1 Identity and Credential Model

There are no service accounts, no long-lived API keys, and no per-agent Anthropic credentials in this architecture. All identity is IAM-based. Human access flows through IAM Identity Centre with corporate SSO. Machine access flows through IAM roles assumed at execution time with ephemeral STS tokens. Headless agent executions — Lambda functions, Step Functions executions, scheduled validation agents — each assume a dedicated least-privilege IAM role. Every Bedrock invocation is automatically logged in CloudTrail with the IAM principal that made it.

## 8.2 Data Classification and Governance

| **Classification**           | **Governance Posture**                                                                                                                                                                                                                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Internal**                 | Standard encryption at rest and in transit. IAM-scoped access. Standard CloudTrail logging. Agent manifest ceiling permits internal data in context window. Accessible to all authenticated employees.                                                                                   |
| **Confidential**             | Dedicated KMS key. Separate Restricted MCP Gateway. Agent manifest ceiling restricts context window content — raw Confidential data is never included in prompt payloads sent to Bedrock. Accessible only to authorised roles. Separate OpenSearch index with dedicated access controls. |
| **PII (any classification)** | Macie detection and redaction in the Glue ETL pipeline before data enters the ingestion pipeline. PII fields anonymised or tokenised before inclusion in Knowledge Base documents. Glean permissions enforcement ensures PII-containing documents are only surfaced to authorised users. |

## 8.3 Guardrails

Bedrock Guardrails enforce content policy at the infrastructure level, independent of the model's own safety training. Guardrail configuration is declared in the agent manifest and enforced by AgentCore before any response reaches the caller. Guardrails cannot be bypassed through prompt engineering — they operate on the input and output of every invocation at the platform level.

| **Guardrail Control** | **Configuration**                                                                                                                                                                     |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Topic denial**      | Agents are restricted to their declared domain. An HR agent cannot discuss finance topics. An IT agent cannot provide legal advice. Topic restrictions are configured per agent type. |
| **Content filtering** | Hate speech, violent content, sexual content, and self-harm content are blocked at all sensitivity levels across all agents.                                                          |
| **Grounding check**   | Automated Reasoning checks validate that agent responses are grounded in the retrieved Knowledge Base content. Hallucinated responses are blocked before reaching the user.           |
| **PII redaction**     | PII in agent responses is automatically detected and redacted or masked before the response is returned. Applies to all agents regardless of data classification ceiling.             |
| **Word policy**       | Competitor mentions and regulatory non-compliant language patterns are flagged or blocked per the organisation's communication policy.                                                |

## 8.4 Audit and Compliance

The platform provides a complete, immutable audit trail of every AI interaction through the combination of CloudTrail, the Prompt Vault, and AgentCore Observability. This satisfies audit requirements for every common regulatory framework the organisation operates under.

| **Audit Record**               | **Contents and Retention**                                                                                                                                                                                                         |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **CloudTrail**                 | Every Bedrock API invocation: IAM principal, model ARN, timestamp, region, source IP, response metadata. Immutable by SCP. Retained in the shared services account log archive per the organisation's retention policy.            |
| **Prompt Vault (S3)**          | Complete assembled context window, guardrail evaluation result, tool calls made, tool results returned, final response. Retained for 90 days standard, 365 days for Confidential-ceiling agents. Encrypted with dedicated KMS key. |
| **AgentCore Observability**    | Step-by-step agent execution trace: reasoning steps, tool invocations, memory reads and writes, quality scores, latency per step. Queryable through CloudWatch and exportable to SIEM.                                             |
| **Quality Records (DynamoDB)** | LLM-as-Judge scores, human annotation records, grounding scores, user feedback signals. Retained indefinitely as the quality history of each agent version.                                                                        |

---

# 9 Multi-Agent Architecture

Multi-agent workflows enable complex tasks that exceed the capability of a single agent operating alone — tasks that benefit from parallel execution, specialist expertise across domains, or long-running orchestration that persists across hours or days. The platform provides native support for multi-agent patterns through AgentCore's supervisor-delegate model and Step Functions workflow orchestration.

## 9.1 Supervisor-Delegate Pattern

A supervisor agent receives a complex task, decomposes it into sub-tasks, delegates each to an appropriate specialist agent, coordinates the results, and synthesises a final response. The supervisor is itself a Claude model invocation with a manifest that grants it orchestration-level tool access. Specialist sub-agents are standard platform agents with narrower, domain-specific manifests.

| **Participant**              | **Role**                                                                                                                                                                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Supervisor Agent**         | Receives the complex task. Reasons about decomposition strategy. Invokes specialist agents through the workflow orchestration tools. Manages shared memory workspace. Synthesises final response from sub-agent outputs. |
| **HR Specialist Agent**      | Handles HR domain queries. Access to HR Policies Knowledge Base and HR system tools. No access to finance or IT tools.                                                                                                   |
| **IT Specialist Agent**      | Handles IT domain queries. Access to IT Procedures Knowledge Base and ServiceNow tools. No access to HR or finance tools.                                                                                                |
| **Glean Research Agent**     | Performs broad enterprise knowledge retrieval. Access to full Glean tool suite. Returns structured findings to the supervisor for synthesis.                                                                             |
| **Document Synthesis Agent** | Takes multiple source inputs and produces a structured output document. Access to document generation tools. No system access tools.                                                                                     |

## 9.2 Step Functions Orchestration

Multi-agent workflow state is managed by AWS Step Functions, exposed to agents as a set of MCP tools through the workflow orchestration tool category in the MCP Gateway. Step Functions provides durable workflow state, declarative retry and exception handling, native timeout management, and a visual console for debugging and audit. The shared memory workspace that agents collaborate through is the Step Functions execution state, versioned and structured per workflow.

## 9.3 Federated Agents

The platform supports federation with agent systems that live outside AgentCore — CrewAI crews, LangGraph workflows, third-party AI services, or agent systems owned by different teams on different infrastructure. Federated agents are exposed through API Gateway endpoints registered as tools in the MCP Gateway. From the supervisor agent's perspective, a federated agent is just another tool invocation. The federation boundary is the API contract.

```text
<strong>External Agent Security</strong>
All federated agent endpoints are fronted by API Gateway — no direct internet access from AgentCore.
Authentication to external systems is handled by API Gateway through managed credentials, not by agents directly.
Data classification ceiling in the calling agent's ToolPolicy governs what data can be sent to a federated endpoint.
All federated agent invocations are logged through the MCP Gateway's standard observability pipeline.
External agents running on non-AWS infrastructure connect through PrivateLink or secured public HTTPS endpoints validated by WAF.
```

---

# 10 Observability and Quality

## 10.1 Observability Stack

| **Component**               | **Purpose**                                                                                                                                                                                                  |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **AgentCore Observability** | Step-by-step agent execution traces. Every reasoning step, tool call, memory access, and guardrail evaluation is captured with timing metadata. OTEL compatible — exports to Datadog, Dynatrace, or Grafana. |
| **CloudWatch Metrics**      | Platform operational metrics: invocation count, latency percentiles (P50/P95/P99), error rates, token consumption, cost per agent. Custom metrics for quality scores and guardrail block rates.              |
| **CloudWatch Alarms**       | Automated alerting on SLA breaches, error rate spikes, cost anomalies, and absence of expected scheduled execution signals. SNS notifications to PagerDuty for production agents.                            |
| **Grafana Dashboards**      | Unified visibility across all agents and all accounts. Per-agent quality trend charts, cost attribution by team, deployment health, Knowledge Base freshness indicators.                                     |
| **X-Ray Tracing**           | Distributed traces across Lambda invocations. All platform Lambda functions run with `Active` mode tracing — the Lambda service creates a trace segment for every invocation automatically. A platform-level sampling rule (5%, 1 trace/sec guaranteed) and a named service group are provisioned centrally in the platform layer. Each Lambda execution role holds `xray:PutTraceSegments` and `xray:PutTelemetryRecords`. Lambda handlers annotate traces with `Platform` and `Service` keys (via `aws_xray_sdk`) so traces are scoped to the platform group's ServiceMap view. The SDK is loaded with a graceful import — if not packaged, traces still appear in X-Ray at the Lambda service level. To activate full SDK instrumentation including boto3 subsegments, add `aws_xray_sdk` to the Lambda deployment package. |
| **Prompt Vault**            | Complete interaction records in S3 for audit, quality review, and training data purposes. Queryable via Athena for aggregate analysis.                                                                       |

## 10.2 Quality Pipeline

Every production agent interaction is evaluated by an automated quality pipeline. Claude Haiku acts as an LLM-as-Judge evaluator, scoring each interaction across five dimensions: correctness, relevance, groundedness, completeness, and tone. Interactions below threshold are routed to human review. Interactions above threshold are eligible for inclusion in the golden dataset that drives future prompt improvements.

| **Quality Dimension** | **What It Measures**                                              | **Target Score** |
| ----------------------- | ------------------------------------------------------------------- | ------------------ |
| **Correctness**       | Factual accuracy of the response against the retrieved knowledge  | \>= 0.85         |
| **Relevance**         | Whether the response addresses what the user actually asked       | \>= 0.80         |
| **Groundedness**      | Whether claims in the response are supported by retrieved context | \>= 0.75         |
| **Completeness**      | Whether all aspects of the question are addressed                 | \>= 0.75         |
| **Tone and Format**   | Appropriate register, formatting, and length for the agent type   | \>= 0.80         |

---

# 11 Change Control and Release Management

Change control for an AI platform spans a wider surface than traditional software change management. A change may touch the agent manifest, the system prompt, the Knowledge Base content, the MCP tool definitions, the embedding model, the guardrail configuration, or the underlying foundation model ARN — and each combination carries a different risk profile and warrants a different approval and validation path. This section defines the unified change control framework that governs all changes across the agent estate.

## 11.1 Change Categorisation

All changes to platform components are categorised by risk tier before entering the promotion pipeline. The tier determines the approval requirements, the testing obligations, and the rollout strategy.

| **Tier**                 | **Change Types**                                                                                                                                                                                                          | **Approval and Rollout Requirements**                                                                                                                                                                                                                                          |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tier 1 — Standard**    | System prompt wording refinements within existing scope. Knowledge Base document additions or updates. MCP tool documentation updates. Observability configuration changes.                                               | Automated quality gate validation in staging. No manual approval required if all gates pass. Full canary rollout pattern (5% \> 25% \> 50% \> 100%) with automated rollback triggers active.                                                                                   |
| **Tier 2 — Significant** | New tool added to agent ToolPolicy. Knowledge Base chunking strategy change. Guardrail configuration changes. Agent scope expansion. New agent type deployment. Glean connector additions.                                | Automated quality gate validation plus platform engineer manual review of staging results. Explicit sign-off required before production promotion. Canary rollout with extended 48-hour hold at 5% before progression.                                                         |
| **Tier 3 — Major**       | Foundation model ARN change (version upgrade). Embedding model change requiring full index rebuild. New data classification ceiling assignment. Cross-agent shared memory schema changes. MCP Gateway structural changes. | Automated validation plus platform lead and security review sign-off. Architecture review for changes that affect multiple agents simultaneously. Staged rollout with manual progression approval at each canary stage. Full rollback plan documented before promotion begins. |
| **Tier 4 — Emergency**   | Immediate disablement of a production agent causing active harm. Rollback of a deployment actively degrading quality or causing cost anomalies. Security incident response requiring immediate configuration change.      | Fast-path procedure — see Section 11.4. Compensating controls documented. Full post-incident review within 48 hours.                                                                                                                                                           |

## 11.2 Agent Version Registry and Estate Visibility

The agent version registry is the authoritative record of what is deployed where across the entire agent estate at any point in time. Without it, the platform team cannot answer fundamental operational questions — which agents are running in production, what version of each, when was each last updated, and which agents are affected by a given change.

| **Registry Component**         | **Description**                                                                                                                                                                                                                                                                                                                     |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Agent inventory (DynamoDB)** | Every agent registered on the platform has a record in the Agent Registry table: agent ID, display name, owning team, current manifest version, deployment status per environment, last deployment timestamp, and rollback version. Updated automatically by the CodePipeline deployment Lambda on every successful promotion.      |
| **Version history**            | The Agent Registry retains the full deployment history for each agent — every manifest version that has been promoted to each environment, the timestamp, the IAM principal that triggered the promotion, and the quality gate results at the time of promotion. Retained for 24 months for audit purposes.                         |
| **Estate dashboard (Grafana)** | A dedicated Grafana dashboard provides real-time visibility of the full agent estate — all agents, current version per environment, deployment health, quality score trend, and cost per agent. Queryable by team, by environment, by data classification ceiling, and by agent type.                                               |
| **Drift detection**            | A scheduled Lambda runs every 6 hours and compares the running AgentCore configuration for each agent against the version declared in the Agent Registry. Any discrepancy — indicating a manual change that bypassed the pipeline — fires an immediate alert to the platform lead and creates a compliance finding in Security Hub. |

## 11.3 Coordinated Multi-Component Change Management

Some changes necessarily touch multiple platform components simultaneously — a new tool added to the MCP Gateway alongside a manifest update that uses it, or a Knowledge Base rebuild combined with an embedding model upgrade. Rolling back one component of a coordinated change without the others leaves the system in an inconsistent state. Coordinated changes require explicit planning before any component enters the promotion pipeline.

| **Coordination Step**         | **Description**                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Change dependency mapping** | Before a coordinated change enters the pipeline, the submitting team documents the complete set of components being changed and the dependency order between them. Which component must be deployed first, which components are safe to deploy in parallel, and which must wait for others to complete and validate.                             |
| **Atomic promotion planning** | For changes where partial deployment creates an inconsistent state, the promotion plan defines the components as an atomic unit. Either all components promote together or none do. The pipeline enforces this through a coordination gate that holds all dependent components until the leading component has passed its quality gates.         |
| **Coordinated rollback**      | The rollback plan for a coordinated change is documented before promotion begins. For each component in the change, the rollback sequence is defined explicitly — which component is rolled back first, what state the system is in at each stage of the rollback, and what the acceptance criterion is for confirming the rollback is complete. |
| **Coordinated change record** | All coordinated changes are recorded in the change log with the full component list, dependency map, promotion sequence, and outcome. This record is the audit evidence that the change was planned, reviewed, and executed according to the declared plan.                                                                                      |

## 11.4 Emergency Change Fast-Path

The standard promotion pipeline enforces quality gates and staged rollout that take hours to days to complete. When a production agent is actively causing harm — returning dangerous content, exposing data beyond its classification ceiling, generating runaway costs, or behaving in a way that creates legal or reputational risk — the organisation cannot wait for the standard pipeline. The emergency change fast-path provides a governed mechanism for immediate action.

```text
<strong>Emergency Change Triggers</strong>
Agent returning content that violates guardrail policy or data classification ceiling.
Agent generating Bedrock costs at more than 5x the expected daily rate with no explainable cause.
Agent exposed to a security vulnerability requiring immediate configuration change.
Agent producing systematically incorrect outputs at a rate that indicates a deployment failure rather than normal quality variation.
Active security incident requiring immediate disablement of one or more agents.
```

| **Fast-Path Step**        | **Description**                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Immediate disablement** | The platform lead or on-call engineer can immediately update the AgentCore alias to point to a known-good previous version, or disable the agent endpoint entirely through a single API call. This takes effect on the next request — there is no pipeline delay. The action is logged in CloudTrail automatically.                                                              |
| **Compensating controls** | If the agent cannot be immediately rolled back, compensating controls are applied — guardrail configuration tightened to block the problematic behaviour, ToolPolicy updated to remove the tool causing the issue, or rate limits reduced to contain cost impact. These changes are applied directly and documented immediately.                                                 |
| **Fast-path approval**    | Emergency changes require verbal approval from the platform lead or their designated on-call delegate. Approval is documented in a Slack message with a timestamp and the approver's name within 15 minutes of the change being made. The full written change record follows within 2 hours.                                                                                     |
| **Post-incident review**  | Every emergency change triggers a post-incident review within 48 hours. The review covers root cause, timeline, impact assessment, the change made, and the remediation steps to prevent recurrence. The review outcome is added to the change log and drives a documentation update if the gap that caused the incident was not already covered by the platform knowledge base. |

## 11.5 Compliance Evidence Retention

The promotion pipeline generates compliance evidence implicitly — every promotion, approval, quality gate result, and deployment action is recorded automatically. The following describes where that evidence lives and how it is assembled for audit purposes.

| **Evidence Type**            | **Location and Retention**                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Deployment history**       | CodePipeline execution history in the shared services account. Retains the full pipeline execution record for every promotion including approval timestamps and approver identity. Retained for 24 months.                                                                                                                                                                                                  |
| **Quality gate results**     | DynamoDB quality records table. Every golden dataset test run, LLM-as-Judge score, and human review outcome is stored with the agent version, environment, and timestamp. Retained indefinitely.                                                                                                                                                                                                            |
| **Approval records**         | CloudTrail records every CodePipeline manual approval action with the IAM principal who approved, the timestamp, and the pipeline execution ID. Retained in the shared services CloudTrail archive per the organisation's retention policy.                                                                                                                                                                 |
| **Change log**               | A structured change log is maintained in the platform documentation repository as a version-controlled markdown file. Every Tier 2, Tier 3, and Tier 4 change is recorded with the change description, risk tier, approval chain, rollout outcome, and any incidents or rollbacks. The change log is the human-readable audit narrative that complements the automated CloudTrail and CodePipeline records. |
| **Emergency change records** | Emergency change records are stored in a dedicated DynamoDB table with the trigger event, the change made, the compensating controls applied, the approval record, and the post-incident review outcome. Retained for 36 months.                                                                                                                                                                            |

---

# 12 Enterprise Rollout Roadmap

The rollout follows a four-phase sequence. Each phase has a defined completion criterion before the next begins. The sequence is designed to build confidence at each layer before adding the next layer of complexity.

## Phase 1 — Foundation (Weeks 1-6)

Establish the AWS organisational structure, deploy the shared services account infrastructure, and build the initial platform knowledge base.

1.  Deploy AWS Control Tower with the account structure defined in Section 3. Establish management account, shared services account, and the OU hierarchy.

2.  Configure SCPs for all OUs. Verify that model ARN restrictions, data residency enforcement, and CloudTrail immutability are active.

3.  Configure IAM Identity Centre with corporate SSO integration. Provision permission sets and validate access across all accounts.

4.  Deploy Bedrock in the Internal Production and External Production accounts. Enable Claude Sonnet, Claude Haiku, and Titan Embeddings. Validate IAM policy scoping.

5.  Deploy the platform documentation repository in the shared services account. Write the initial knowledge base covering manifest schema, pipeline templates, governance policies, and MCP tool catalogue.

6.  Configure Claude Code enterprise-wide to use Bedrock as the backend. Validate that all Claude Code invocations appear in CloudTrail with correct IAM tagging.

7.  Deploy the staging and development accounts with appropriate SCP and networking configuration.

**Phase 1 Completion Criterion**  
A platform engineer can scaffold a basic agent manifest, pipeline configuration, and observability setup using Claude Code without hitting any documentation gaps. All resources are deployed, all IAM boundaries are active, all CloudTrail logging is confirmed.

## Phase 2 — First Agents (Weeks 6-12)

Deploy the first production agents, onboard the first engineering teams, and stress-test the platform knowledge base against real builds.

8.  Deploy the HR Assistant agent as the first production agent. Full pipeline from development through staging to production with canary rollout.

9.  Deploy the IT Support agent as the second production agent. Validate that MCP Gateway tool routing, rate limiting, and ToolPolicy enforcement operate correctly.

10. Integrate Glean. Register Glean MCP tools in the Gateway. Deploy the Glean Search, Expert Lookup, and Code Search tools. Validate permission-scoped result filtering.

11. Onboard the first application engineering team using the quick start package. Track gap PR rate. All gaps become documentation PRs merged before the second team onboards.

12. Onboard the second team. Compare gap PR rate to the first onboarding. Declining rate confirms the documentation flywheel is working.

13. Establish the 24-hour PR review norm for documentation PRs. Validate that Claude Code PR review is running automatically on PR creation.

**Phase 2 Completion Criterion**  
Two production agents are live and operating within SLA. Two engineering teams have onboarded without platform team involvement beyond PR approvals. Documentation gap PR rate is declining between onboardings.

## Phase 3 — Self-Service (Weeks 12-24)

Any engineering team can onboard and build their first production agent without platform team involvement. Time-to-first-agent target is under eight hours.

14. Deploy the Quality Pipeline — LLM-as-Judge scoring, Prompt Vault, human annotation portal, golden dataset production, and prompt registry A/B evaluation.

15. Deploy scheduled validation agents for the MCP tool catalogue and Knowledge Base configurations. Validate that schema drift and authentication failures are surfaced as PRs before causing production failures.

16. Deploy the multi-agent workflow infrastructure — Step Functions workflow templates, shared memory workspace tooling, and supervisor agent patterns.

17. Onboard a third and fourth team with the explicit target of zero platform team involvement beyond PR approvals. Measure time-to-first-agent for each.

18. Publish the knowledge base health metrics dashboard — gap PR rate, time-to-first-agent, Claude clarification rate, PR merge time, documentation coverage.

19. Run the first platform engineer and Claude Code partnership session — build a new agent type together with documentation improvement as an explicit goal.

**Phase 3 Completion Criterion**  
Time-to-first-agent is under eight hours for new teams. Claude clarification rate is under three unresolvable gaps per agent build for established agent types. Scheduled validation agents are running and have surfaced at least one meaningful finding.

## Phase 4 — Acceleration (Ongoing)

The platform is self-improving. The platform team's role shifts from delivery to curation, architecture evolution, and quality oversight.

20. Every new platform capability — new tool, new Knowledge Base, new pipeline pattern, new governance policy — is documented before deployment. Documentation is the specification.

21. Monthly review of knowledge base health metrics. Address any sections showing increasing gap rates.

22. Quarterly embedding model evaluation. Assess whether newer embedding models warrant an index rebuild based on Precision@5, Recall@10, and MRR measurements.

23. Annual platform strategy review. Measure adoption velocity, agent deployment frequency, quality score trends, and total cost of ownership against the projections in this document.

---

# 13 Cost Model and Governance

All AI platform costs flow through a single AWS consolidated bill. There are no separate Anthropic, Glean-infrastructure, or AgentCore invoices. Cost attribution, budget alerts, and anomaly detection operate through standard AWS tooling at every level of the organisational hierarchy.

## 12.1 Primary Cost Drivers

| **Cost Driver**                              | **Primary Lever**                                                                                                                                                                  | **Governance Mechanism**                                                                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| **Bedrock model invocations**                | Model selection per agent type. Haiku for high-volume evaluation tasks. Sonnet for reasoning-intensive production tasks.                                                           | ToolPolicy restricts model ARNs per agent. Budget alerts per account. SCP limits to approved ARNs.                                 |
| **OpenSearch Serverless (long-term memory)** | Selective enablement per agent type. Only agents where relational continuity generates demonstrated value. Periodic memory consolidation to prune stale records.                   | Memory configuration in agent manifest. Monthly storage review. Retention policy enforced by TTL configuration.                    |
| **Glean subscription**                       | Enterprise subscription cost is fixed. Marginal cost per tool invocation through the MCP Gateway is effectively zero relative to the subscription cost.                            | Glean ToolPolicy restricts which agents can invoke Glean tools. Rate limiting at the Gateway prevents unbounded query volume.      |
| **S3 (Prompt Vault)**                        | Retention policy per classification tier. 90-day standard, 365-day Confidential. Intelligent tiering after 30 days moves infrequently accessed records to cheaper storage classes. | Lifecycle policies configured on the Prompt Vault bucket. Data classification ceiling in manifest drives retention tier selection. |
| **Claude Code (Bedrock)**                    | Usage-based through consolidated billing. Tagged by team for chargeback visibility.                                                                                                | Budget alerts per team tag. Cost anomaly detection in Cost Explorer. Model tier restrictions via IAM.                              |

## 12.2 Budget Structure

| **Budget Level**                            | **Alert Configuration**                                                                                                                                                                                   |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Organisation total (management account)** | Monthly total AI platform spend. 80% threshold notification to platform lead and finance. 100% threshold escalation to CTO.                                                                               |
| **Per production account**                  | Monthly per-account spend. 80% threshold notification to account owner. Automated IAM restriction action at 100% to limit further high-cost model invocations.                                            |
| **Per development account**                 | Hard monthly cap enforced by AWS Budgets Actions. Restricts provisioning of non-development-appropriate services at cap. Engineers receive notification at 70%.                                           |
| **Cost anomaly detection**                  | AWS Cost Anomaly Detection monitors for unexpected spend patterns. Threshold: any single-day Bedrock spend more than 3 standard deviations above the 30-day rolling average fires an immediate SNS alert. |

| **A Appendix A — AWS Service Reference** |
| ------------------------------------------ |

| **Service**               | **Role in Architecture**                                                      | **Account Scope**                         |
| --------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------- |
| **Amazon Bedrock**        | Foundation model API. Knowledge Bases. Guardrails. Prompt Management.         | All workload accounts                     |
| **Bedrock AgentCore**     | Agent runtime, memory, MCP Gateway, identity, observability.                  | All workload accounts                     |
| **AWS Organizations**     | Account hierarchy, consolidated billing, SCP enforcement.                     | Management account                        |
| **AWS Control Tower**     | Landing zone, account vending, baseline governance.                           | Management account                        |
| **IAM Identity Centre**   | Centralised human identity, SSO integration, permission sets.                 | Management account                        |
| **AWS Glue**              | ETL for document preparation before KB ingestion. PII detection coordination. | All workload accounts                     |
| **Amazon Macie**          | PII detection in S3 buckets during ingestion pipeline.                        | All workload accounts                     |
| **OpenSearch Serverless** | Vector store for Knowledge Base indexes and long-term agent memory.           | All workload accounts                     |
| **Amazon DynamoDB**       | Session memory, agent registry, quality records, ingestion job tracking.      | All workload accounts                     |
| **AWS Step Functions**    | Multi-agent workflow orchestration. Shared memory state management.           | All workload accounts                     |
| **AWS Lambda**            | Ingestion orchestrator, quality scorer, gap resolution, event handlers.       | All workload accounts                     |
| **Amazon EventBridge**    | Event routing for ingestion pipeline, quality pipeline, monitoring.           | All workload accounts                     |
| **Amazon S3**             | Document landing zone, processed documents, Prompt Vault, platform docs.      | All workload accounts                     |
| **AWS CodePipeline**      | Agent promotion pipeline from development through production.                 | Shared services + workload                |
| **Amazon API Gateway**    | MCP Gateway HTTP layer. Federated agent endpoints. CLI access.                | All workload accounts                     |
| **Amazon CloudWatch**     | Metrics, alarms, logs, dashboards for all platform observability.             | All workload accounts                     |
| **AWS CloudTrail**        | Immutable audit trail for all API calls including all Bedrock invocations.    | All accounts — archive in shared services |
| **AWS KMS**               | Encryption key management. Dedicated keys per data classification tier.       | All workload accounts                     |
| **Amazon Cognito**        | User pool authentication for external-facing agent endpoints.                 | External production account               |
| **AWS WAF**               | Web application firewall for external production agent endpoints.             | External production account               |
| **AWS Budgets**           | Cost threshold alerts and automated restriction actions.                      | Management account + all accounts         |
| **Amazon Athena**         | SQL queries over Prompt Vault S3 data for quality analysis.                   | Shared services account                   |

| **B Appendix B — Platform Maturity Reference** |
| ------------------------------------------------ |

Understanding the maturity and tenure of each platform component is important context for risk assessment and executive communication.

| **Component**         | **Key Dates**                                                            | **Maturity Signal**                                                                                                                                                                                        |
| ----------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Amazon Bedrock**    | Announced: April 2023. General Availability: September 28, 2023.         | 18+ months GA. 100,000+ organisations worldwide. Production-hardened. Full AWS SLA and support coverage.                                                                                                   |
| **Claude on Bedrock** | Available at Bedrock GA: September 2023. Anthropic was a launch partner. | 18+ months available. Continuous model updates (Claude 3, 3.5, 4.x) delivered through Bedrock without re-architecture.                                                                                     |
| **AgentCore**         | Preview: July 16, 2025. General Availability: October 13, 2025.          | 5 months GA. 1M+ SDK downloads before GA. Enterprise adopters include Ericsson, Sony, Thomson Reuters. Rapidly evolving — Policy and Evaluations added December 2025.                                      |
| **Claude Code**       | Research preview: February 2025. General Availability: May 2025.         | 10 months GA. \$1B+ annualised revenue by November 2025. Adopted internally by Microsoft engineering teams. Strongest adoption signal in the developer tooling market.                                     |
| **Glean**             | Founded 2019. Enterprise search GA 2021. MCP server capability: 2025.    | Mature enterprise search platform with 6+ years of production operation. 100+ enterprise connectors. Named CNBC Top 50 Disruptor 2025. MCP integration is recent but the search platform itself is proven. |

**Risk Assessment Summary**  
The foundational layer — Bedrock and Claude on Bedrock — carries the lowest technical risk of any component in this architecture. It is the most mature, most broadly adopted, and most thoroughly battle-tested element. AgentCore is newer but enters a well-understood problem space with strong early enterprise adoption and AWS's full investment behind it. Claude Code's commercial velocity provides strong evidence of product-market fit. The architecture is not a bet on emerging technology — it is an early but well-evidenced adoption of technology that is clearly winning.
