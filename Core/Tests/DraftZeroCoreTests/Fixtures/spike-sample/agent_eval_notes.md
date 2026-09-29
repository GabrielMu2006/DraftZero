# Notes on evaluating LLM agents

Most leaderboards test single-turn QA, which tells us little about whether a model can carry a long task through to the end. I want a tiered task suite instead:

- Tier 1: retrieval plus restatement.
- Tier 2: synthesis across several documents.
- Tier 3: the model must decompose the goal, call tools, and recover from its own errors.

Score completion rate separately from process efficiency. A model that succeeds in eight steps is not the same as one that succeeds in six. Plan: hand-write thirty tasks first and check that every task statement is unambiguous before running anything.
