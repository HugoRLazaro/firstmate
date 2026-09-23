---
name: edicion
description: >-
  The marking route: open a replica of a real screen, let the captain click a block and write what he wants, then turn the accumulated marks into real work.
  Use when the captain invokes /edicion, asks to mark something in a screen, asks for a change without touching code, or when marks already delivered must be read or applied.
user-invocable: true
metadata:
  internal: true
---

# edicion

`/edicion` is the captain's no-code change route: he marks blocks on a replica of a real screen, writes what he wants of each one, and firstmate turns the accumulated marks into work.
This skill is the only owner of the `/edicion` trigger and of the route's shape.
[`bin/fm-edicion.sh`](../../../bin/fm-edicion.sh) owns the mechanics: its header owns the delivery contract, the surface contract, and the environment, and its `--help` owns the exact flags.

## When to load

- The captain invokes `/edicion`, or asks to mark something in a screen, request a change from the interface, or ask for a change without touching code.
- A `check:` wake reports marks waiting in `data/edicion/` (the surface notifies through `bin/fm-inbox.sh`).
- The captain answers an open question about a mark whose anchor was lost.

## The route

1. **Open.** `bin/fm-edicion.sh abrir <pantalla>` (or `abrir <url>`) starts the project clone's marking surface and opens the replica.
   Tell the captain, in plain words, the address and that his marks are collected in `data/edicion/`; he marks at his own pace and can keep adding marks.
2. **Read.** `bin/fm-edicion.sh marcas` lists the pending deliveries with their marks and applies nothing.
   Marks whose anchor is lost are listed as such; see the anchoring rules below before applying.
3. **Apply.** `bin/fm-edicion.sh aplicar` turns the pending deliveries into one task: a backlog item, `data/<id>/brief.md` with one binding instruction per mark quoting the marked block's text, and a durable sidecar per delivery.
   `--fichero` names deliveries and groups them into one task; `--tarea <id>` sends the instructions to a live task with `bin/fm-send.sh` instead of creating one.
   A delivery already applied is left to `cerrar`, or takes `--marca` to resolve a held-back mark.
   The created task then rides the ordinary lifecycle: dispatch it like any other queued item.
4. **Close.** `bin/fm-edicion.sh cerrar <entrega>` moves an applied delivery to `data/edicion/aplicadas/` and records the result in its ledger.
   It refuses while any mark of that delivery is neither delivered nor discarded; `--descartar <id>` (repeatable) records that a held-back mark is discarded, and the ledger names every discarded mark.
5. **Acknowledge.** When a `bin/fm-inbox.sh` note announced the marks, close it with `bin/fm-inbox.sh drain --ack <id>` once handled.

## Anchoring rules

A mark is applied only when `ancla` is `estable` and it carries the marked block's text.
Anything else - `perdida`, an unknown value, or no citable block - is held back: it is presented with its original context (block text, original route, what was asked) and left pending an answer, because the block is no longer where the mark left it.
Take that question to the captain with his own nouns; once he answers, deliver the mark with `aplicar --fichero <entrega> --marca <id>` - which creates the task when the delivery has none - or with `aplicar --fichero <entrega> --tarea <id> --marca <id>` to send it to a live task.
An applied delivery stays bound to the task it first became and resolves only the marks it still owes.
If he decides against it, record the discard with `cerrar <entrega> --descartar <id>`.
Only then can the delivery close.

## Hard rules

- Never write under `projects/`: the route writes only under `data/`, and the screen registry lives in the project's own repository, where it is consumed, never copied here.
- The delivery format and the surface contract are frozen and shared with the platform half; read them in the script header and do not change them here.
- The notice channel is `bin/fm-inbox.sh`, which the surface already uses; never write wake-queue records by hand.
- Delivery mode and merge authority stay the ordinary per-task decisions: `aplicar` defaults to the project's registered posture, and `--modo` is for a deliberate, recorded deviation.
