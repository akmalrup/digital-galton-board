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
#set heading(numbering: "1.1")
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

= Introduction
#todo[Short explanation of what was done. Audience is yourselves in a few years.]

- What a Galton board is (pegs, bins, left/right bounces).
- Idealized math: Bernoulli trials $->$ binomial $->$ Gaussian via the CLT.
- What we built: RP2350 VGA animation of colliding balls, DMA "thunk" audio, rotary-encoder UI, live histogram.
- High-level result: max balls at 60 fps, parameters the user can tune.

= Design and Testing Methods

== High-level architecture
#todo[Cores, threads, DMA, VGA double-buffer, SPI DAC. Why this split.]

- Core 0 / Core 1 responsibilities.
- Protothreads vs. DMA vs. PIO (who owns the 60 fps budget).
- Data that is shared (ball count, bounciness, histogram) and how it is protected.

== Hardware

=== Rotary encoder
#todo[GPIO, quadrature decoding, pushbutton debounce, mode cycling.]

- Channels A/B and the built-in switch.
- State machine for clockwise / counterclockwise counts.
- Button: cycle encoder modes (ball count, bounciness, #todo[5730 extra parameter]).
- VGA indication of the active mode.

=== VGA and double buffering
#todo[Hsync / Vsync / RGB GPIOs, 640$times$480 Hz, why double-buffering.]

=== SPI DAC and DMA thunk
#todo[MCP4822 wiring, SPI clock, DMA ping-pong / ring buffer, trigger-on-new-peg.]

- Why DMA instead of interrupt-based synthesis.
- How a collision arms a DMA transfer without stalling physics.

=== LED deadline indicator
#todo[GPIO 25 (or equivalent): on if a frame misses 60 fps.]

== Software

=== Fixed-point arithmetic and collision physics
#todo[Format (e.g. s15.16), gravity, walls, spawn, coefficient of restitution.]

- Position/velocity update each frame.
- Broad-phase AABB vs. exact distance (alpha max + beta min vs. `sqrt`).
- Teleport-out of the peg, normal vector, energy loss on *new* peg only.
- Last-peg tracking so one contact does not spam DMA.

=== Galton board geometry
#todo[16 rows, peg spacing, bin mapping under the bottom row.]

=== Histogram
#todo[Which bin a ball falls into; normalize bar height to leftover VGA space; reset on parameter change.]

=== Optimization for 60 fps
#todo[What actually bought balls: fixed-point, early-outs, multicore, overclock, fewer `sqrt`s, etc.]

- Metric: balls sustained at 60 fps (LED off).
- Tradeoffs you rejected and why.

== Testing
#todo[Tests whose outcomes would convince a TA the spec is met.]

#figure(
  table(
    columns: (1.4fr, 1.6fr, 1.4fr),
    inset: 6pt,
    align: left,
    stroke: 0.5pt,
    table.header[*Requirement*][*Test*][*Pass criterion*],
    [Encoder CW / CCW], [Rotate while watching VGA count], [Increments / decrements reliably],
    [One ball, one peg (Wk 1)], [Drop, collide, thunk, respawn], [Audible DMA hit; gravity; auto-respawn],
    [16-row board, $>=$10 balls (Wk 2)], [Visual + serial], [All collide, thunk on *new* peg, respawn],
    [Live stats], [VGA overlay], [active balls, total fallen, time since boot],
    [Histogram], [Let balls accumulate], [17 bins; height uses space under the board],
    [Max balls @ 60 fps (Wk 3)], [Boot + LED], [LED off at advertised $N_"max"$],
    [Encoder modes], [Click through states], [VGA shows mode; rotation edits that param],
    [Param change resets stats], [Twist encoder mid-run], [Histogram and total-fallen go to 0],
    [Deadline LED], [Force overload], [LED on iff frame $>$ 16.67 ms],
  ),
  caption: [Verification matrix. Fill in measured outcomes in Results.],
)

== AI use
#todo[Tools, what they generated, what you accepted, how you verified it. Cite like any other source.]

- Labeled AI-generated code in the listing.
- Prompt log in the appendix (timestamps, suggested vs. accepted edits).

= Documentation

== System schematic
#todo[Pico GPIOs $->$ encoder, VGA resistor DAC, MCP4822, LED, grounds.]

== Software structure
#todo[Thread / ISR / DMA flowchart; ball-update loop; encoder mode machine.]

== Key algorithms (commented excerpts)
#todo[Paste only the non-obvious pieces here (collision, encoder FSM, DMA arming). Full listing in the appendix.]

= Results

== Frame timing and ball capacity
#todo[Max balls at 60 fps. Frame time vs. $N$. Overclock if used.]

== Histogram vs. ideal binomial / Gaussian
#todo[Screenshot of the board + histogram. Overlay or compare to $B(n=16, p=1/2)$.]

== Parameter sweeps
#todo[Bounciness (and any 5730 extra param): qualitative effect on the distribution and on frame time.]

== Accuracy / error sources
#todo[Missed pegs, tunneling, correlated bounces, spawn bias, fixed-point quantization.]

= Conclusions
#todo[Usability, what you would redo, complaints, suggested lab improvements.]

= Lab questions

== CLT assumptions on the physical model
Our simulated board is not an idealized sequence of independent fair coin flips.

*Independence.* #todo[Do successive left/right outcomes share state (velocity, last peg, walls)?]

*Identically distributed.* #todo[Same $p$ at every peg and for every ball? Gravity, bounciness, spawn jitter.]

*Finite variance.* #todo[Almost certainly yes --- bounded bins.]

*Why a Gaussian still appears.* #todo[Name the relevant CLT generalization (e.g. Lindeberg--Feller / Lyapunov; weakly dependent variables). No proof required.]

== Why more rows improve the Gaussian approximation
#todo[De Moivre--Laplace / Berry--Esseen: error shrinks as $n$ (rows) grows. Binomial $->$ continuous envelope.]

== Mean and standard deviation for a 16-row ideal board
For an ideal board with $n = 16$ rows and $p = 1/2$ left/right at each peg, the bin index $K ~ "Binomial"(n, p)$ satisfies

$
  mu = n p = 8, wide
  sigma = sqrt(n p (1-p)) = 2.
$

#todo[State how you number bins (0..16 vs. 1..17) so $mu$ is unambiguous. If you plot in pixels, convert.]

= Appendix A --- Commented program listing
#todo[Heavily commented source. Mark AI-generated regions.]

// Example once you copy encoder.c next to this file:
// #raw(read("../encoder.c"), lang: "c", block: true)

= Appendix B --- AI prompt log
#todo[For each prompt: time, words exchanged, edits suggested, insertions / deletions / modifications accepted.]
