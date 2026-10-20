import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";

// Execute production SQL against a real SQLite database; only D1's asynchronous transport is adapted.
export function testDatabase(
  options: { beforeRun?: (query: string) => Promise<void> } = {},
) {
  const sql = new DatabaseSync(":memory:");
  sql.exec("PRAGMA foreign_keys=ON");
  for (const name of readdirSync("migrations")
    .filter((n) => n.endsWith(".sql"))
    .sort())
    sql.exec(readFileSync("migrations/" + name, "utf8"));
  class Statement {
    constructor(
      readonly query: string,
      readonly args: SQLInputValue[] = [],
    ) {}
    bind(...args: SQLInputValue[]) {
      return new Statement(this.query, args);
    }
    async first(column?: string) {
      const row = sql.prepare(this.query).get(...this.args);
      return row ? (column ? row[column] : row) : null;
    }
    async all() {
      return {
        success: true,
        results: sql.prepare(this.query).all(...this.args),
        meta: {},
      };
    }
    async run() {
      await options.beforeRun?.(this.query);
      const r = sql.prepare(this.query).run(...this.args);
      return {
        success: true,
        results: [],
        meta: {
          changes: Number(r.changes),
          last_row_id: Number(r.lastInsertRowid),
        },
      };
    }
  }
  const adapter = {
    prepare: (query: string) => new Statement(query),
    async batch(statements: Statement[]) {
      sql.exec("BEGIN");
      try {
        const results = [];
        for (const statement of statements) results.push(await statement.run());
        sql.exec("COMMIT");
        return results;
      } catch (error) {
        sql.exec("ROLLBACK");
        throw error;
      }
    },
  };
  // D1 has additional session/export APIs unused by this isolated adapter.
  return { sql, DB: adapter as unknown as D1Database };
}
