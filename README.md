# Simple Project Reporting

This repository defines a structured ontology for tracking:

- Daily execution logs
- Weekly goals
- Weekly reviews
- Allocation categories
- Execution state per contributor

The objective is to create a consistent, machine-readable representation of project activity that enables:

- Goal tracking
- Allocation analysis
- Execution monitoring
- Blocker identification
- Weekly review automation

---

# Core Concepts

## 1. Allocation

Allocation answers:

Where is the contributor spending time relative to this project?

Allowed values:

- core: Work directly contributing to this project’s roadmap or goals.
- client: Work for a paying client that is strategically related to this project.
- outside_client: Work for a paying client that is NOT related to this project.
- outside_internal: Internal company work not related to this project.
- away: Not working (OOO, sick leave, vacation, etc.)

Allocation is orthogonal to execution state.

---

## 2. Execution State

Execution state answers:

What is the contributor’s operational status relative to this project?

Allowed values:

- active: Making progress on assigned work.
- blocked: Unable to make progress due to a blocker.
- supporting: Supporting work, reviews, or coordination.
- inactive: Not engaged with the project.
- away: Not working at all (OOO).

Important:

- A person can be active but allocated to outside_client.
- A person working on unrelated internal tasks is active with outside_internal.
- A person OOO is away allocation and away execution_state.

---

## 3. Daily Entry Schema (v5)

Each daily file contains:

- Date
- Member entries
- Allocation
- Execution state
- Description
- Optional goal reference
- Optional blocker information

Example:

date: 2026-02-13

entries:
  - member: Abdul
    allocation: core
    execution_state: active
    description: Improving SQL refinement and follow-up questions, checking GCP tools
    goal_ids: [W06-G1]

  - member: Rakshit
    allocation: client
    execution_state: blocked
    description: Stuck on TPJ setup for Everygene
    goal_ids: [W06-G2]
    blocker:
      description: TPJ environment not configured
      owner: DevOps

---

## 4. Weekly Goals Schema

Weekly goals define intended outcomes for a specific week.

Each goal has:

- goal_id
- description
- owner(s)
- measurable acceptance criteria
- optional Jira reference
- status (updated in weekly review)

Example:

week: 2026-W06

goals:
  - goal_id: W06-G1
    description: Improve NLP pipeline performance
    owners: [Bunyamin]
    acceptance_criteria:
      - Pass benchmark suite v2
      - Reduce error rate by 20%
    jira: PROJ-123
    status: in_progress

Allowed status values:

- not_started
- in_progress
- achieved
- partially_achieved
- not_achieved
- blocked
- deferred

---

## 5. Weekly Review Schema

The weekly review evaluates goal achievement and execution health.

Example:

week: 2026-W06

review:
  goals:
    - goal_id: W06-G1
      final_status: achieved
      evidence:
        - Benchmark suite v2 passed
        - 23% error reduction
      comments: Improvement validated in staging

    - goal_id: W06-G2
      final_status: blocked
      evidence:
        - TPJ setup incomplete
      comments: Blocked by infra configuration

  summary:
    core_allocation_ratio: 0.62
    blocked_members: [Rakshit]
    major_risks:
      - Infra dependencies slowing client integration
    recommendations:
      - Escalate TPJ setup

---

# Goal Achievement Strategy

Weekly goals are evaluated using:

1. Explicit references in daily logs (goal_ids)
2. Blocker tracking
3. Measurable acceptance criteria
4. Weekly review status updates

Daily logs indicate activity.

Weekly review determines outcome.

This avoids mixing execution tracking with evaluation logic.

---

# Design Principles

1. Allocation and execution state are orthogonal.
2. Client work is strategically important and separated into related and unrelated.
3. OOO is explicit.
4. Goals are outcome-based, not activity-based.
5. Weekly review is authoritative for goal completion.
6. Daily logs are evidence, not judgment.

---

# Recommended Folder Structure

project/
  daily/
    2026-02-10.yaml
    2026-02-11.yaml
    2026-02-12.yaml
    2026-02-13.yaml

  weekly_goals/
    2026-W06.yaml

  weekly_reviews/
    2026-W06.yaml

  schema/
    v5.md

---

# Future Extensions (Optional)

- Add time tracking (hours per allocation)
- Add risk scoring per week
- Add contributor velocity metrics
- Add automated goal completion inference
- Add dashboard generation
