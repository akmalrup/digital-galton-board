#set document(
  title: "ECE 4760 Lab 2: Digital Galton Board",
  author: ("TODO: Name 1", "TODO: Name 2"),
)
#set page(
  paper: "us-letter",
  margin: 1in,
  numbering: "1",
)
#set text(font: "New Computer Modern", size: 11pt)
// Number only the main sections ("1.", "2.", ...); subheadings stay unnumbered
#set heading(numbering: (..n) => if n.pos().len() == 1 { numbering("1.", ..n) })
#set par(justify: true, leading: 0.65em)
#show link: set text(fill: blue)

#let todo(body) = text(fill: rgb("#b45309"), style: "italic")[TODO: #body]

#align(center)[
  #text(size: 16pt, weight: "bold")[ECE 4760 / 5730 --- Lab 2]
  #v(0.4em)
  #text(size: 20pt, weight: "bold")[Digital Galton Board]
  #v(0.6em)
  #text(size: 12pt)[
    #todo[Author 1] \u{00B7} #todo[Author 2] \
    Cornell University \
    #todo[Lab section / TA] \u{00B7} #datetime.today().display("[month repr:long] [day], [year]")
  ]
]

#v(1em)
#outline(indent: auto, depth: 2)
#pagebreak()

// ============================================================
= Introduction
// ============================================================
#todo[One short paragraph covering the points below.]

- What a Galton board is: balls bounce left or right off rows of pegs and pile up in bins.
- The ideal math: each bounce is a coin flip, so the bin counts follow a binomial distribution that looks like a Gaussian.
- What we built: an RP2350 VGA animation of balls hitting pegs, a DMA "thunk" sound on collisions, rotary-encoder controls, and a live histogram.
- Headline result: the most balls we kept running at 60 fps.

// ============================================================
= Design and Testing Methods
// ============================================================

== System overview
#todo[How the work is split between the two cores and why.]

- Core 1 runs the physics for every ball. Core 0 draws the pegs, histogram, text, and balls.
- Two semaphores keep the cores in step once per frame.
- System clock overclocked to 200 MHz.

== Hardware
#todo[Short description of each part and how it is wired.]

- Rotary encoder: channel A on GPIO 14, channel B on GPIO 15, pushbutton on GPIO 13.
- VGA: Hsync on GPIO 16, Vsync on GPIO 17, color on GPIO 18--21 through the resistor DAC.
- MCP4822 DAC on SPI0 (GPIO 4--7).
- Deadline LED on GPIO 25.

== Software

=== Ball physics
#todo[Fixed-point format, gravity, walls, respawn, bounciness.]

=== Peg collisions
#todo[How a hit is detected and handled.]

- Alpha-max-beta-min distance instead of `sqrt`.
- Push the ball out of the peg, reflect its velocity, then scale by bounciness.
- Only check the 1--2 pegs near each ball instead of all 136.

=== Board layout and histogram
#todo[Peg grid and how balls are counted.]

- 16 rows, 136 pegs, 19 px spacing.
- 17 bins, 38 px wide, lined up with the bottom row of pegs.
- Bars are scaled to the tallest bin and reset when a setting changes.

=== DMA thunk sound
#todo[Sound table, DMA setup, and how a collision starts the sound without slowing the physics.]

- #todo[Does the thunk play on every collision or only on a new peg?]

=== Encoder modes and on-screen display
#todo[How the user changes settings and what the screen shows.]

- Button cycles: number of balls #sym.arrow bounciness #sym.arrow gravity #sym.arrow ball radius. The active mode is shown in blue.
- Screen shows balls fallen, seconds since boot, current settings, and per-core timing.

== Getting to 60 fps
#todo[What let us run more balls, and what we tried and reverted.]

- Measure of success: number of balls at 60 fps with the LED off.

== Testing
#todo[Fill in which tests were run. Measured outcomes go in Results.]

#figure(
  table(
    columns: (1.4fr, 1.6fr, 1.4fr),
    inset: 6pt,
    align: left,
    stroke: 0.5pt,
    table.header[*Requirement*][*Test*][*Pass criterion*],
    [Encoder CW / CCW], [Rotate while watching VGA count], [Increments / decrements reliably],
    [One ball, one peg (Wk 1)], [Drop, collide, thunk, respawn], [Audible thunk; gravity; auto-respawn],
    [16-row board, $>=$10 balls (Wk 2)], [Watch VGA], [All collide, thunk, respawn],
    [Live stats], [VGA overlay], [Active balls, total fallen, time since boot],
    [Histogram], [Let balls build up], [17 bins; bars fit under the board],
    [Max balls @ 60 fps (Wk 3)], [Raise ball count, watch LED], [LED off at $N_"max"$],
    [Encoder modes], [Click through modes], [VGA shows mode; rotating edits that setting],
    [Setting change resets stats], [Turn encoder mid-run], [Histogram and total fallen go to 0],
    [Deadline LED], [Overload the system], [LED on only when frame $>$ 16.67 ms],
  ),
  caption: [Verification tests.],
)

== AI use
#todo[Tools used, what they generated, what we kept, and how we checked it. AI-written code is labeled in Appendix A; full prompt log in Appendix B.]

// ============================================================
= Documentation
// ============================================================

== Wiring diagram
#todo[Pico GPIOs to encoder, VGA resistor DAC, MCP4822, LED, and grounds.]

== Software flowchart
#todo[One frame across both cores, and the encoder mode cycle.]

== Key code excerpts
#todo[Short commented pieces: collision check, nearby-peg lookup, encoder interrupt, DMA setup. Full listing in Appendix A.]

// ============================================================
= Results
// ============================================================

== Speed
#todo[Max balls at 60 fps. Physics / draw / frame time breakdown.]

== Accuracy
#todo[Screenshot of the board and histogram, compared to the ideal $B(16, 1/2)$. Sources of error (missed pegs, balls passing through pegs, spawn bias, fixed-point rounding).]

== Effect of settings
#todo[What changing bounciness, gravity, and ball radius does to the distribution and to frame time.]

// ============================================================
= Conclusions
// ============================================================
#todo[How usable it was, what we would do differently, and feedback on the lab.]

// ============================================================
= Lab Questions
// ============================================================

== Question 1
_Our physical model of the Galton Board differs from the idealized model. In order for the Central Limit Theorem to hold, all random numbers must be *independent*, *identically distributed*, and have *finite variance.* Which of these assumptions hold for our physical Galton Board model, and which do not? Why do we still see a distribution that approaches a Gaussian? (You needn't prove anything here, just try to identify the generalization of the CLT that is responsible for this)._

#todo[Answer.]

== Question 2
_The Gaussian approximates the distribution under the Galton board *better* with *more rows in the board*. Why?_

#todo[Answer.]

== Question 3
_For your 16-row Galton Board, what is the mean and standard deviation of the Gaussian which approximates the resulting distribution (under the assumption that your Galton Board is "ideal")?_

#todo[Answer.]

// ============================================================
#heading(numbering: none)[Appendix A --- Commented Program Listing]
// ============================================================
#todo[Full commented source with AI-written parts marked.]

// #raw(read("../encoder.c"), lang: "c", block: true)

// ============================================================
#heading(numbering: none)[Appendix B --- AI Prompt Log]
// ============================================================
#todo[For each prompt: time, what was asked, edits suggested, and edits accepted.]
