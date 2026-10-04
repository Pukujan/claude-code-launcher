## Planning goes to a sub-agent on opus

Always hand planning, design and multi-step breakdowns to a sub-agent running on the opus model: use the `planner` agent (or any sub-agent with `model: opus`), give it the goal, constraints and relevant paths, then carry out the plan it returns yourself. If a skill you are following (for example superpowers) has its own planning steps, keep following the skill; this only decides which model does the planning.
