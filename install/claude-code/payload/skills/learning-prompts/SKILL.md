---
name: learning-prompts
description: Turns "I want to learn/master X" into a fully-instantiated, ready-to-paste teaching prompt, using one of 6 proven patterns (fast-track 80/20, adaptive personal tutor, structured university course, quiz-style knowledge tester, one-shot expert breakdown, or time-boxed mastery roadmap). Use this whenever the user wants to learn, study, master, get tutored in, get quizzed on, or build a curriculum/study plan/roadmap for any topic or skill - including phrasings like "teach me X", "help me get good at X", "I have N days to learn X", "quiz me on X", "explain X like I'm going from beginner to advanced", or "make me a study plan for X". Also use it if the user wants to generate or compare prompt templates for learning, or wants a reusable prompt they can paste into ChatGPT, Gemini, or any other LLM.
---

# Learning Prompts

Six prompt patterns for turning "I want to learn X" into a sharp, ready-to-use directive instead of a vague request. Each pattern optimizes for a different learning goal - picking the right one matters more than the wording, since a fast-track learner handed a 90-day roadmap will bounce off it just as hard as a deadline-driven learner handed a meandering open-ended explanation.

## How to use this

1. Identify the topic and, if possible, which of the 6 patterns fits (see "Picking a pattern" below). If the user already named a pattern, or the goal is obvious from phrasing, skip straight to instantiating it.
2. If it's not obvious, ask ONE quick question to disambiguate rather than guessing - the patterns produce meaningfully different outputs, and guessing wrong wastes a round trip.
3. Fill in the chosen template with the topic and anything else the user mentioned (a deadline, a skill level, a specific sub-area, a duration).
4. Show the finished prompt in a copyable code block - this is the actual deliverable, not just a means to an end. The user may want to paste it somewhere else entirely (ChatGPT, a teammate, a notes app).
5. Then offer to run it right now, in this conversation, too. Most people asking for this want both the portable prompt AND the answer, not just one.

Don't silently pick a pattern and start answering the underlying question directly - the whole point of this skill is the specific SHAPE of the response (paced tutor vs. one-shot breakdown vs. quiz loop vs. curriculum), and collapsing that shape into a generic answer defeats the purpose.

## Picking a pattern

| Signal in the request | Pattern |
|---|---|
| "fast", "just the essentials", "don't have time for the whole thing" - wants leverage, not completeness | 80/20 Learning |
| Wants an ongoing back-and-forth; mentions not understanding something yet; wants pacing that adapts turn by turn | Personal Tutor |
| Wants full structure, "everything", comprehensive, no particular urgency - treats it like a real course | University Course |
| Wants to check what they already know; "quiz me", "test me"; prepping for an exam or interview | Knowledge Tester |
| Wants one comprehensive answer right now; "explain like the world's expert"; not looking for a back-and-forth | Expert Breakdown |
| Names a deadline or duration ("90 days", "before my trip", "this quarter"); wants a plan with checkpoints | Mastery Roadmap |

If more than one applies, or none clearly do, ask: "Do you want this as one deep explanation right now, an ongoing back-and-forth where I pace it to how you're doing, a structured multi-week plan, or a quiz to check what you already know?" Those four options cover all 6 patterns - "structured multi-week plan" spans both University Course and Mastery Roadmap, so follow up on whether there's a real deadline to pick between those two.

## The 6 patterns

Each block is the literal template - replace `{TOPIC}` (and any other bracketed field) and it ships as-is. These are deliberately terse; the pattern is doing the work, not extra flourish.

### 1. 80/20 Learning

Use when the user wants the highest-leverage subset of a topic fast, not full mastery.

```
I want to learn {TOPIC}. Teach me the 20% of concepts that will give me 80% of the results. Skip unnecessary theory and focus on the highest-leverage knowledge with real-world examples.
```

### 2. Personal Tutor

Use when the user wants an adaptive, ongoing teaching relationship rather than a single answer. This pattern is a standing instruction for the rest of the conversation (it gates pacing on comprehension), not a one-shot output - say so when you hand it back, since a single response can't fulfill "don't move on until I've understood."

```
Act as my private tutor for {TOPIC}. Teach me from beginner to advanced using simple explanations, analogies, quizzes, and practical exercises. Don't move to the next lesson until I've understood the current one.
```

### 3. University Course

Use when the user wants comprehensive structure - modules, objectives, milestones - over a longer stretch, with no specific deadline pressure.

```
Create a complete university-level curriculum for mastering {TOPIC}. Break it into weekly modules with learning objectives, practice tasks, recommended resources, and milestone projects to track my progress.
```

### 4. Knowledge Tester

Use when the user wants active recall or self-assessment rather than fresh instruction - checking what they already know, exam or interview prep. Like Personal Tutor, this is a standing instruction for an ongoing quiz loop, not a single-turn output.

```
Test my knowledge of {TOPIC} with progressively harder questions. After every answer, explain what I got right, what I missed, and teach me the underlying concept before moving on.
```

### 5. Expert Breakdown

Use when the user wants one comprehensive, authoritative answer right now - not a back-and-forth, not a multi-week plan.

```
Explain {TOPIC} as if you're the world's leading expert. Start with the fundamentals, then uncover advanced insights, common misconceptions, mental models, and practical applications that most people never learn.
```

### 6. Mastery Roadmap

Use when the user names or implies a timeframe and wants a plan shaped around it, with a cadence of practice and review - the project-management version of learning a topic.

```
I want to become one of the top 1% in {TOPIC}. Build a {DURATION}-day learning roadmap with daily study goals, hands-on projects, deliberate practice exercises, and weekly reviews that maximize long-term retention and real expertise.
```

Default `{DURATION}` to 90 only if the user gave no timeframe at all. If they mentioned any real constraint ("before my certification exam", "this summer"), use that instead of the default so the roadmap actually fits their calendar.

## The two multi-turn patterns need real follow-through

Personal Tutor and Knowledge Tester are both built around pacing across many turns (don't advance until understood; progressively harder questions after each answer), not a single response. When you hand back one of these two and the user wants to start now rather than just take the portable text elsewhere, actually commit to the loop for the rest of the conversation: track where they are (which concept, which difficulty level) instead of restating the instruction once and reverting to normal Q&A after the first exchange.

If the user only wants the prompt text to use somewhere else (e.g. "give me the tutor prompt so I can paste it into ChatGPT"), that's the right call too - just don't assume that's what they want without checking, since most people asking for a tutor or a quiz want to actually start right now.

## Source

These 6 patterns were reverse-engineered from a public social-media post of "prompts for learning X" templates - a common, recognizable genre, not proprietary to any product.
