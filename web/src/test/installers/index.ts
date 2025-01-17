import {describe, it} from "mocha";
import {expect} from "chai";
import { Installer } from "../../installers";

describe("Resolve version", () => {

  it("resolves correct version without .x", async () => {
    const version = await Installer.resolveVersion("rook", "1.0.4");
    expect(version).to.equal("1.0.4");
  });

  it("resolves correct version with .x", async () => {
    const version = await Installer.resolveVersion("kubernetes", "1.17.x");
    expect(version).to.equal("1.17.13");
  });

  it("resolves correct rook 1.0 version with .x", async () => {
    const version = await Installer.resolveVersion("rook", "1.0.x");
    expect(version).to.match(/^1\.0\.4-14\.2\.[\d]+/);
  });

  it("resolves latest", async () => {
    const version = await Installer.resolveVersion("rook", "latest");
    expect(version).to.match(/^1\.[\d]+\.[\d]+/);
  });

});

describe("greatest", () => {

  it("resolves greatest openebs", () => {
    const version = Installer.greatest(["1.12.0", "1.6.0", "3.2.0", "2.12.9", "2.6.0"]);
    expect(version).to.equal("3.2.0");
  });

});
