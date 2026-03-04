import { describe, it, expect, afterEach } from "vitest";
import { render, screen, cleanup, act } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { alert, confirm, prompt, DialogProvider } from "./Dialog";

describe("Dialog", () => {
  afterEach(cleanup);

  describe("without DialogProvider", () => {
    it("alert resolves immediately", async () => {
      // With no provider mounted, showDialogFn is null, so alert resolves
      await expect(alert("test")).resolves.toBeUndefined();
    });

    it("confirm resolves with false", async () => {
      await expect(confirm("test")).resolves.toBe(false);
    });

    it("prompt resolves with null", async () => {
      await expect(prompt("test")).resolves.toBeNull();
    });
  });

  describe("with DialogProvider", () => {
    it("confirm OK resolves true", async () => {
      const user = userEvent.setup();
      render(<DialogProvider />);

      let result!: Promise<boolean>;
      act(() => {
        result = confirm("Are you sure?");
      });

      const okButton = await screen.findByText("OK");
      await user.click(okButton);
      await expect(result).resolves.toBe(true);
    });

    it("confirm Cancel resolves false", async () => {
      const user = userEvent.setup();
      render(<DialogProvider />);

      let result!: Promise<boolean>;
      act(() => {
        result = confirm("Are you sure?");
      });

      const cancelButton = await screen.findByText("Cancel");
      await user.click(cancelButton);
      await expect(result).resolves.toBe(false);
    });

    it("prompt resolves with typed input", async () => {
      const user = userEvent.setup();
      render(<DialogProvider />);

      let result!: Promise<string | null>;
      act(() => {
        result = prompt("Enter name:", "default");
      });

      const input = await screen.findByRole("textbox");
      await user.clear(input);
      await user.type(input, "Alice");

      const okButton = screen.getByText("OK");
      await user.click(okButton);

      await expect(result).resolves.toBe("Alice");
    });
  });
});
