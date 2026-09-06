import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Execute the production guard without launching a GUI helper or requesting
// macOS permissions. The rest of the native helper is checked by swiftc.
test.skipIf(process.platform !== "darwin")("native Computer Use authorization follows live session lease", async () => {
  const source = await readFile(new URL("./ShidouComputerUse.swift", import.meta.url), "utf8");
  const guard = source.slice(
    source.indexOf("private enum ComputerUseAuthorization {"),
    source.indexOf("private final class BridgeProcessRegistration {"),
  );
  expect(guard).toContain("static func check");
  const directory = await mkdtemp(join(tmpdir(), "shidou-computer-use-authorization-"));
  try {
    const script = join(directory, "test.swift");
    await writeFile(script, `import Foundation
      enum HelperError: Error { case invalidRequest(String) }
      func commandLineArgument(_ name: String) -> String? { nil }
      ${guard}
      let directory = CommandLine.arguments[1]
      let lease = URL(fileURLWithPath: directory).appendingPathComponent("enabled")
      func denied() -> Bool {
          do { try ComputerUseAuthorization.check(directory: directory); return false }
          catch { return true }
      }
      try ComputerUseAuthorization.check(directory: nil)
      precondition(denied(), "missing lease must deny")
      try Data("enabled".utf8).write(to: lease)
      try ComputerUseAuthorization.check(directory: directory)
      try FileManager.default.removeItem(at: lease)
      precondition(denied(), "an already running helper must observe disable")
      try Data("enabled".utf8).write(to: lease)
      try ComputerUseAuthorization.check(directory: directory)
      try Data("invalid".utf8).write(to: lease)
      precondition(denied(), "invalid lease must deny")
      try FileManager.default.removeItem(at: lease)
      try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false)
      precondition(denied(), "unreadable lease must deny")
    `);
    const process = Bun.spawn(["xcrun", "swift", script, directory], { stdout: "pipe", stderr: "pipe" });
    const stderr = await new Response(process.stderr).text();
    expect(await process.exited, stderr).toBe(0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}, 60_000);
