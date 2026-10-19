// Stands in for the Teal Brick relay (a stdio MCP server): records the environment Claude Code gave it, then idles.
import { writeFileSync } from "node:fs";
writeFileSync(process.argv[2], JSON.stringify(process.env));
process.stdin.resume();
