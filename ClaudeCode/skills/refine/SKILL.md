---
name: refine
description: Tighten a piece of writing, a plan, a proposal, a ticket description or a document so it says one thing, in the house style, consistent with the documents around it. Use this whenever the user asks to refine, tighten, polish, clean up, de-AI, improve, review the wording of, or make consistent any prose or plan, and whenever a draft is about to be posted somewhere (Confluence, Jira, a PR body, an email) even if the request is only "does this read OK?". Produces marked-up text for review in one message, never an in-place edit, and stops before the text only for a question that changes its shape.
---

# Refine

A target document is rarely wrong in isolation. It is wrong because it repeats a sibling, invents a synonym for a glossary term, explains a mechanism the reader already knows, or exists at all when two lines on a sibling would serve. Refining is therefore a reading and a placing job before it is a writing job: read the target, map what sits around it, decide whether and where the target belongs, and only then cut.

The output is a proposal, never an edit. The work runs in two passes: settle the shape and the change list, then write the marked-up text against that shape. Only the text is shown, and the one stop is for the user's yes to it. Settling the shape first keeps the longest part of the work from being written against the wrong shape, and an in-place rewrite hides what changed.

## 1. The style guide and the glossary

The style guide is the user-level and organisation-managed `CLAUDE.md` files. Both are in context in a normal session, so do not re-read them. Apply them, and name the rule only where a change would otherwise look arbitrary.

When the target's repo or space owns a glossary, the glossary's word wins over any synonym in the target. One listing of the repo's `docs/reference` or a single `find` for `glossary`, `terms` or `definitions` settles whether one exists. Do not hunt further.

## 2. Map the adjacent documents cheaply

Adjacent means whatever else a reader of the target would read: sibling files in the same folder, pages the target links to, pages that link to it, the parent ticket and its siblings, the README that introduces the folder. The point of reading them is to find overlap, boundaries, term conflicts and stale copies. Reading every sibling in full finds those at far greater cost than asking for them directly, so work from the target outwards and let grep answer what grep can.

1. **Read the target once**, and while reading list its distinctive nouns (component names, actions, identifiers), every link out of it, and every list it copies from somewhere else (hooks, make targets, workflows, variables, account names, status values).
2. **One grep, not many reads.** Grep the sibling set for those nouns and the target's heading words in a single call with `-e` patterns, so one command returns every file that shares its vocabulary. Grep for the target's filename to find the pages that link in.
3. **Check copied lists by grep, both ways, without reading the owner.** For each list the target copies, one grep of the owning file with every item as an `-e` pattern shows which items the owner lacks. One grep of the owner for its item shape (the hook id lines, the target names, the variable blocks) lists what the owner has that the target lacks. Two calls and a few lines back, against reading the whole file. A drifted copy is a finding, and the fix is a pointer to the owner, not a corrected copy.
4. **Re-verify every claim of fact against the current code**, not the target's last draft. A PR body or README that says a thing is off, pending or unsupported is checked against the branch merged with its base, because the base moves between drafts. A claim that no longer holds is a finding, and the text states the end state.
5. **Read in full only what the grep implicates**: a sibling that shares a heading, a page the target links to for a definition, the parent ticket. Skim the rest at heading level with a grep for `^#`.
5. **Stop at one hop.** The siblings' siblings are out of scope unless the grep shows the target's vocabulary there.

What the map must yield:

- **Overlap.** A paragraph that restates a sibling belongs in one place. The document whose title names the fact owns it, and the copy becomes a link or a one-line pointer.
- **Boundaries.** Where two documents cover the same ground from different angles, each should say in a line what it covers and where the rest lives.
- **Consistency.** Each concept gets one name, status word and capitalisation across the set. A term only the target uses adopts the sibling's or the glossary's term. It becomes a question only when no document in the set names the concept and the new name is the user's to choose.
- **Stale copies.** Every drifted list from step 3, naming both files.

## 3. Zoom out before cutting

Line edits to a document that should not exist, or should be two documents, waste a review round. Before any line edit, place the target in its set and its programme by answering these.

- **Reader and next action.** Who reads this and what do they do straight after?
- **Single purpose.** What one claim, decision or procedure is the document for? A document with two purposes is usually two documents or one plus a link.
- **Place in the set.** Which sibling would the reader open before this one, and which after? If the answer is "none", the document may be unlinked or redundant.
- **Place in the programme.** Which epic, roadmap item, platform component or decision does this serve, and does the document say so in one sentence with a link?
- **Does it earn its place?** Would deleting it and adding two lines to the owning sibling serve the reader better? Would splitting it make each half findable? Should a boundary between it and a sibling move?

Where the last question has a real answer other than "keep as is", write the text against that shape and state the shape in the scope. The shape becomes a question only when two shapes serve the reader about equally and the choice turns on something the documents cannot show, such as who maintains the page or where it will be published.

Every paragraph is then tested against the reader and the purpose. A paragraph that does not help that reader do that next thing goes, however well written. So does a paragraph that explains the programme at length where a sentence and a link would do.

## 4. Reduce

Work in this order, because each pass makes the next one cheaper.

1. **Remove.** Repetition within the target, repetition of a sibling, background the reader has, journey words and changelog ("previously", "no longer", "for now"), framing and reassurance, closing offers, summaries that restate the body.
2. **Flatten.** An abstraction standing in for one concrete case becomes that case. A three-level heading tree with one paragraph per leaf becomes a list. A table with one varying column becomes a list. A diagram described in prose becomes the diagram or the prose, not both.
3. **Unify.** One term per concept, the glossary's. One tense. One form of each name (product names as the product writes them, Terraform names as the code has them). One home per fact, with the others linking to it.
4. **Strip AI-isms.** The list is below. Last, because the earlier passes remove most of them and what survives is easier to see.
5. **Apply the style rules.** UK spelling, acronyms expanded once, no em dashes, no semicolon splices, no capitals for emphasis, no hard-wrapped prose, bold only for the one or two points a skimmer must not miss, blocked words out.

Be aggressive. Aim for a third to a half of the words gone and nothing the reader needed lost.

### AI-isms

Each of these manages the reader instead of informing them, or fills space a fact should occupy. Remove on sight. The sentence survives without it or does not survive at all. Where the blocked-word lists in the `CLAUDE.md` files differ from this list, they win.

- Importance filler and signposting: "it is worth noting", "importantly", "crucially", "the key thing", "in this document we will", "as mentioned above", "let's dive in". Cut, and put the point first.
- Framing openers and reassurance: "in today's", "when it comes to", "at its core", "rest assured", "this is a great question". Cut.
- Hedged asides and self-vouching: "it could be argued", "arguably", "to some extent", "honestly", "to be clear", "the real issue". Make the claim, or put the open point as a question with options.
- Additive framing: "also", "plus", "in addition", "furthermore", "moreover", "additionally". Cut the word and merge or split the sentence.
- Reflex triplets ("fast, reliable and scalable") and contrast by negation ("not just a tool, a platform"). Keep the one checkable adjective, or state the positive.
- Rhetorical questions, closing summaries that restate the body, closing offers ("let me know if", "happy to iterate"). Answer, cut, cut.
- Elevated verbs and nouns: delve, leverage, utilise, facilitate, harness, unlock, empower, foster, streamline, underscore, bolster; landscape, ecosystem, journey, realm, paradigm, synergy, "a testament to". Plain verb, specific noun.
- Vague intensifiers and small-word emphasis: significant, robust, comprehensive, seamless, holistic, cutting-edge; own, itself, at all, exactly, very, really. Replace with the measure or cut.
- Em dashes, semicolon splices, colon-spliced headings ("Outcome: the system is faster"), bold on every clause, emoji in headings. Two sentences, a plain heading, bold for one or two points.
- Journey words and dated stamps: previously, no longer, renamed from, going forward, "(as of June 2026)". State the end state. Git and the ticket carry the when.
- Narrating the source ("the README states that X"). Claim X, cite in a parenthetical.
- Over-qualified verbs and nominalisations: "serves to", "aims to", "is designed to", "the implementation of", "the provision of". The verb alone.
- Agentless passives hiding a decision ("it was decided that"). Name who decided, or make the claim directly.
- Lists of one, tables with one row. Prose.
- Justification clauses that explain the repo to its own maintainers: "because ADR-0009's topology has no NAT gateway", "the way wobble does", "attaches that policy to nothing". The reader of a PR body or a unit comment works here. State what the change is, and keep a reference only where the reader has to open it. A cross-reference to a sibling as an analogy is jargon, so name the concrete fact the analogy stands for, within what the data-hygiene rules allow.
- Operating slang standing in for a setting: "drained", "turned up", "stocked". Name the setting and its value ("`desired_count` is 0, so no task runs").
- An open question left as a question: "the assumption for a reviewer is whether X", "unconfirmed, settled at first bring-up". Verify it before the text is written: upstream source through the GitHub connection when a docs site is outside the fetch allowlist, a dev apply, a probe. Then state the fact with its source. Text that flags a checkable unknown is unfinished, not candid.
- Tallies that announce a list or a set: "three questions", "the four things that change", "two pressures forced the decision". Drop the number. The list shows the count, and the number goes stale when someone adds an item. Keep a number only where it is a limit or a design commitment the sentence exists to state ("at most five lines", "one stop").

## 5. Present the proposal

The map, the zoom-out answers and the change list are working, not output. Show the user one message, in chat, unfenced except where noted.

**Scope.** At most five lines above the text: the target, the adjacent documents read, and the shape where it differs from the target's present shape.

**Marked-up text.** For prose, editing notation: deletions as `~~struck through~~`, additions as `**bold**` (or `{+added+}` where bold already carries meaning in the document), unchanged text plain. Where under about half the paragraphs change, show only the changed paragraphs, each under its heading path, with a line of unchanged text either side for placing. Where more than that changes, or the structure changes, show the full revised text with the notation applied. For code, configuration, structured data and diagrams, show a unified diff in a fenced `diff` block, produced with `diff -u` between the original and a scratchpad copy rather than written by hand. Where a cut removes a fact, one line under that paragraph says where the fact lives.

**Open questions.** Ask only what the target, its neighbours and the house rules cannot settle, and only where the answer would change the text: a fact only the user knows, or a decision that is theirs and has no default. These are not questions: a choice with an obvious default, a recommended option offered beside a cheaper one nobody would pick, and a scope choice a house rule already answers (one conceptual change per PR, one home per fact). Take the default, write the text against it, and state it in one line under the heading Assumed, so the user can overturn it with a word. A real question is a lettered choice with the recommendation first and a line of trade-off per option. Where its answer changes the shape, ask it alone and write no text until it is answered. Where it changes a sentence, write the text against the recommendation and put the question under it. Omit both headings when empty.

Then stop. Do not edit the file, post to Confluence or Jira, or write a PR body until the user says yes to the text. Then apply it as shown and report the paths touched in one line.

## Examples

**Request:** "refine docs/explanation/flow-joining.md"

Read the target, grep `docs/explanation` for its nouns and for `flow-joining` to find inbound links, and read the siblings and tickets the grep implicates. Zoom out: the reader is a developer checking the joining sequence before building it, and the document earns its place, but two bullets restate a decision its ticket owns. Shown: a scope of a few lines, then the marked-up paragraphs under their headings, with the restated bullets replaced by a link to the ticket, a struck term renamed to the glossary's word, the closing summary cut and the "it is worth noting" openers stripped. Under Assumed, one line saying the siblings carrying the struck term get the same rename in a separate change.

**Request:** "can you tighten this before I put it on the ticket?" followed by pasted text

The adjacent set is the ticket, its parent epic and siblings. Read the ticket and the epic description, and grep the sibling summaries for the pasted text's nouns. Zoom out: does the text belong on the ticket or on the epic? Shown: the marked-up text ready to paste, with anything the epic already says cut and status words aligned with the project's workflow. Ask before posting.

**Request:** "this terraform README is a mess"

Adjacent is the repo's principles and explanation docs, found by grepping for the README's section nouns. A README is a map, so anything it explains at length that a linked document owns goes. Check every list it copies (hooks, make targets, workflows) against the owning file by grep both ways, without reading those files. Shown: the scope naming the shape, the drift findings, then the full revised text in editing notation, since most of the file changes, and the layout block as `diff -u` output.
