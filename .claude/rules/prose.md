# Prose rules

These apply to every piece of text a person will read: page copy, headings, navigation and button labels, alt text, titles and meta descriptions, error and empty states, README and docs. They do not apply to code, code comments, or commit messages.

The aim is copy that reads as written by a specific person about a specific thing. The phrasing habits listed in section 4 are symptoms. The usual cause is a sentence with nothing specific to say, so the rules start with content.

## 1. Content comes from the project and the owner

- Write only what you can back from the repo, from what the owner told you, or from a source you can link. Never invent numbers, benchmarks, customers, testimonials, user counts, history, or motivations.
- When a passage needs a fact you don't have, put `TODO(copy): <the question>` where the text would go, and list the open questions at the end of your turn. A missing section is better than a filled-in one.
- Before drafting a page, write one sentence for yourself naming who reads it and what they came to find out. If you can't, ask the owner.
- If `docs/voice.md` exists, read it before writing and match it: sentence length, grammatical person, humor, bluntness, what it leaves unsaid. Follow the owner's habits even where they break a rule below. Jokes, opinions, and personality come from the owner's material only.

## 2. Sentences

- Use the specific: the name, number, command, version, file, limit, date. Write "parses a 2 GB log in 4 s on an M2 Air" in place of a speed adjective. If a sentence has no specific to offer, it probably has nothing to say, so cut it.
- Open with the thing itself. The first sentence of a page says what this is and who it's for.
- Make each point once. Don't restate it in the next sentence, at the end of the paragraph, or at the end of the page.
- Use plain verbs: is, has, does, runs, costs, lets you.
- Call a thing by one name every time.
- A list has as many items as there are things to list. Two is fine, and so is four.
- When you're correcting a belief the reader really holds, say so once. Otherwise state the claim directly and skip the thing it isn't.
- Write full sentences whose length follows the content. Contractions are fine. "You" is fine.
- Say what the thing doesn't do, what's unfinished, and what's awkward about it.
- Punctuate with periods, commas, and parentheses. Don't use em dashes.

## 3. Pages

- A section exists because there is content for it. Don't start from the stock layout (hero tagline, three feature cards, FAQ, closing call to action that repeats the hero) and then write text to fill it.
- Headings are short labels in sentence case that name what's under them.
- Buttons and links say what happens when you click: "Download for Linux", "Read the API docs".
- Use a list when items are parallel and prose when you're explaining. Bold marks the one thing a skimming reader must not miss. No emoji in copy.
- Titles, meta descriptions, and alt text follow the same rules. They describe what's on the page or in the image.

## 4. Reread for these before you finish

Each of these is a reflex. When you find one, rewrite the sentence around a specific fact, or cut it. Swapping in a synonym or a neighboring construction (a semicolon where the dash was, "rather than X, Y" where "not X, but Y" was) leaves the problem in place.

- Sentences that tell the reader something matters, marks a shift, reflects a trend, or plays a role.
- A comma followed by an "-ing" clause that tacks on analysis (", ensuring that…", ", making it…").
- Setup lines that exist to tee up the next one: a short question answered immediately, a colon before a reveal, "Here's the thing".
- Denial followed by correction ("It's not X, it's Y"), and the clipped version ("No X. No Y. Just Z.").
- Three adjectives, three nouns, or three clauses in a row where the count came from habit.
- Text about the text: announcing what a section will cover, summarizing what it covered, "let's", "in short".
- Runs of two- or three-word sentences used for drama.
- Words that vouch for your own sincerity or turn up the volume (the "honestly" and "truly" family), and stacked hedges ("can often help to").
- Figurative words for abstract things where a literal word exists: ideas that "live" or "sit" somewhere, problems you "navigate", a "landscape", a "journey".
- Promises of transformation and adjectives of general excellence, which is the vocabulary of every product page.
- Audience sweeps ("Whether you're a… or a…") and false ranges ("from X to Y").
- A last line that sums up, looks to the future, or tries to be quotable. End on the last piece of information.

## 5. Check

- Reread the finished copy as the visitor and delete every sentence they wouldn't miss.
- If `scripts/prose-lint.mjs` exists, run it on the files you touched (`node scripts/prose-lint.mjs <paths>`) and deal with each hit. A hit can be legitimate, such as a literal use, a proper noun, or a quotation. Leave those and say which ones you left.
- Passing the linter means the known patterns are absent. It doesn't mean the copy is good.
