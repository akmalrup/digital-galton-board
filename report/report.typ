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

A Galton board is a board covered in rows of pegs. A ball dropped in at the top bounces off one pef in each row an dlands in one of the bins at the borrom. In an ideal board, each bounce is like a coin flip where a 50%  chance of going left and a 50% chance of goinf right is possible. That means the number of balls in each bin follows a binomial distribution and with enough rows and balls, the central limit thearem says this turns into a bell-shaped Gaussian curve. In this lab, we built a figital version of a galton board on the RP2350 and showed it on a CGA screen. Balls fall through 16 rows and pefs and bounce off them using collision phyiscs. Everytime the ball hits a peg it makes a sounds that is played with DMA - this is done so that it does not slow the CPU down. A live histogram at the bottom of the screen counts how many balls land in each bin so that you are bale to watch the Gaussian curve form. A rotar yencoder lers the user change the nuber of balls, the bounciness, the graviy, and the ball while the animation runs. Our main goal was to animate as many balls as possible at 60 FPS, and our final design ran ~19k balls without missing timing. 

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

- Button cycles: number of balls #sym.arrow bounciness #sym.arrow gravity #sym.arrow ball radius. #todo[How is the active mode shown now that the screen is 1-bit (black and white)?]
- Screen shows balls fallen, seconds since boot, current settings, and per-core timing.

== Optimizations
We measured success by the number of balls we could run while every frame still finished within 16.67 ms (60 fps), which means the deadline LED stays off. We recorded the new maximum after each round of changes. @tab:opt sums up the steps, and the paragraphs below explain each one.

#figure(
  table(
    columns: (1.3fr, 2.6fr, 1fr),
    inset: 6pt,
    align: (left, left, right),
    stroke: 0.5pt,
    table.header[*Step*][*What changed*][*Max balls at 60 fps*],
    [Starting point], [Physics on Core 1, drawing on Core 0], [450],
    [Semaphore fix], [Core 0 draws balls while Core 1 runs physics], [850],
    [Faster collisions], [Outline-only drawing, alpha-max-beta-min distance, only check nearby pegs], [3,000],
    [Radius-1 balls], [Balls shrunk to 1 px with a fast drawing path], [#todo[$tilde$10,000? confirm]],
    [1-bit color], [Frame buffers shrunk to 1 bit per pixel to free memory], [14,000],
    [Overclock], [System clock raised from 150 MHz to 200 MHz], [#todo[number]],
  ),
  caption: [Maximum number of balls at 60 fps after each optimization.],
) <tab:opt>

*Semaphore fix.* At first, Core 0 told Core 1 to start the physics, drew the pegs and text, and then waited for Core 1 to finish before drawing the balls. This meant drawing the balls and doing the physics never happened at the same time. We moved the "start" signal to the very beginning of the frame and moved the wait to the very end, after the balls are drawn. Now both cores work for almost the whole frame, which roughly doubled the ball count.

*Faster collisions.* These changes made Core 1's physics loop much cheaper:
- We switched from filled shapes to outlines (`drawCircle` and `drawRect` instead of `fillCircle` and `fillRect`), so each ball, peg, and bar sets fewer pixels.
- We replaced the floating-point `sqrt` in the collision check with the alpha-max-beta-min approximation, which only needs a compare, a shift, and an add. Finding the direction of the bounce now takes one divide instead of two.
- Before, every ball was checked against all 136 pegs every frame. Since the rows are 19 px apart and the pegs in a row are 38 px apart, a ball can only touch the nearest peg in at most 2 rows. We work out those pegs directly from the ball's position, so each ball needs at most 2 collision checks instead of 136.

*Radius-1 balls.* We shrank the balls to a radius of 1 pixel. We also added a shortcut to `drawCircle` for a radius of 1. The normal circle algorithm only lights 4 pixels at that size, but it draws each of them 3 times, so the shortcut just draws the 4 pixels once.

*1-bit color.* At this point we ran out of memory, not time. The RP2350 has 520 KB of SRAM. The two VGA frame buffers at 4 bits per pixel took 2 #sym.times 153,600 = 307,200 bytes, and each ball takes 16 bytes (four fix15 numbers), so we could only fit about 12,500 balls. We changed the VGA driver and the RGB PIO program to use 1 bit per pixel (black or white). This shrinks each buffer to 38,400 bytes and frees 230,400 bytes, enough for about 14,400 more balls. The downside is that the screen can only show black and white.

*Overclock.* We raised the system clock from 150 MHz to 200 MHz. To keep the VGA timing correct, we changed the PIO clock dividers from 6 to 8 (so the PIO still runs at 25 MHz) and adjusted the delays in the RGB program.

*Things we tried and undid.* #todo[Why were these reverted?]
- Stochastic rounding
- Separate protothreads for the text and the histogram

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
#todo[Final max balls at 60 fps (see @tab:opt for how we got there). Physics / draw / frame time breakdown from the on-screen timers.]

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
