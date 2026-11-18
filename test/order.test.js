import { test } from "node:test";
import assert from "node:assert/strict";
import { subtotal } from "../src/order.js";
test("subtotal adds line totals in cents", () => assert.equal(subtotal([{ unitCents: 1299, qty: 2 }]), 2598));
