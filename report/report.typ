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
    Akmal Rupasingha, Demetrios Gavalas, Parishee Bajaj\
    Cornell University \
    ECE 5730 Thursday 4:30 \u{00B7} #datetime.today().display("[month repr:long] [day], [year]")
  ]
]

#v(1em)
#outline(indent: auto, depth: 2)
#pagebreak()

// ============================================================
= Introduction
// ============================================================

A Galton board is a board covered in rows of pegs. A ball dropped in at the top bounces off one peg in each row and lands in one of the bins at the bottom. In an ideal board, each bounce is like a coin flip where a 50%  chance of going left and a 50% chance of going right is possible. That means the number of balls in each bin follows a binomial distribution and with enough rows and balls, the central limit theorem says this turns into a bell-shaped Gaussian curve. In this lab, we built a digital version of a galton board on the RP2350 and showed it on a VGA screen. Balls fall through 16 rows of pegs and bounce off them using collision physics. Every time the ball hits a peg it makes a sounds that is played with DMA - this is done so that it does not slow the CPU down. A live histogram at the bottom of the screen counts how many balls land in each bin so that you are able to watch the Gaussian curve form. A rotary encoder lets the user change the number of balls, the bounciness, the gravity, and the ball while the animation runs. Our main goal was to animate as many balls as possible at 60 FPS, and our final design ran \~19k balls without missing timing. 

// ============================================================
= Design and Testing Methods
// ============================================================

== System overview

The final baseline system uses the Pico 2 board with two peripheral devices. The first is a rotary encoder, which exposes terminals which tell us the direction of rotation and whether or not the encoder is pushed down. This encoder is used for user input. The second is the VGA screen. The VGA connector connects to the board via adjacent GPIO pins. 

The program is split into several different interrupt handlers and threads. The peripherals are handled by interrupts. The rotary encoder interrupt is triggered by the debounced A pin. VGA interrupts are triggered on the VSYNC and HSYNC pins to keep timing on the VGA screen accurate. 

The graphics library uses a double-buffered system. One buffer is the active buffer which is written to the monitor by the PIO state machine example code. The other buffer is written to by the graphics library. At the end of a frame time, the buffer pointers are swapped. This prevents the screen tearing when graphics are drawn as the pixels are being read onto the screen. 

In our baseline implementation, all the graphics are drawn in a single thread. The thread generates the same peg positions each time, and then it reads the ball positions from a statically allocated array of structs. 

The ball physics are handled in a separate thread. This thread calls two important functions, one function updates gravity and edge handling for all the balls. The other thread handles collisions between a single ball and a single peg. In our baseline implementation, each ball is checked against every peg for collisions. 

The rotary encoder interrupt handlers handle rotations and pushes of the encoder. A push changes the mode of the encoder control to control different parameters, stored as an enum. Then, rotating the encoder triggers its own handler, which checks the other encoder pin level to increment or decrement the counter value. 

== Hardware
#todo[Short description of each part and how it is wired.]
The main components of the system are the RP2350, rotary encoder, VGA connector PCB, DAC, & the onboard LED. 

The rotary encoder was the main way that users would be able to interact with the system. The encoder could be used both as a push button and a rotary knob. The push button let users cycle through different parameters of the galton board while the rotary knob let users numerically change values of the parameters themselves. 

Since the rotary encoder is a mechanical device, it is prone to bouncing in the same way the keypad was in lab 1. Instead of using a debouncing software finite state machine, we chose to implement a solution in hardware. If we used the software implementation, we would had to run the FSM each time the encoder was rotated or pressed which would have increased the size of our interrupt service routine. This would be disadvantageous when we tried to run as many balls as possible at 60 FPS because it would add 4 additional steps to each ball we rendered. Instead, we used a 0.1 uF capacitor in parallel to ground with output A of the encoder. This would smooth out any  

We also tied the onboard LED on GPIO 25 to a timer that would toggle the LED if the system could not finish a frame at 60 FPS. This would show us if we were actually hitting timing even if our eyes could not tell the difference on the VGA display. 

We used the MCP4822 DAC to output a sound to the speaker. This is the same DAC that we used in the lab 1, but now we used it to output a thunk sound every time a ball hit a peg. 

We interfaced with the VGA display in the same way we did in lab 1, using the PCB that we were provided.
- Rotary encoder: channel A on GPIO 14, channel B on GPIO 15, pushbutton on GPIO 13.
- VGA: Hsync on GPIO 16, Vsync on GPIO 17, color on GPIO 18--21 through the resistor DAC.
- MCP4822 DAC on SPI0 (GPIO 4--7).
- Deadline LED on GPIO 25.

== Software

=== Ball physics
The ball physics are a modified version of the pseudocode on the course website. Each ball is stored as a struct of four fix15 numbers: its x and y position and its x and y velocity. Using fixed point instead of floats keeps most of the math as integer adds and multiplies, which are much cheaper on the RP2350.

In our baseline implementation, the physics run in a simple loop. At the start of each frame, it does two passes over the balls. The first pass calls `updateBallPhysics` on every ball. This function adds the velocity to the position, adds gravity to the y velocity, and handles the edges of the screen. If a ball hits the left or right wall, it is placed back on the wall and its x velocity is flipped. If a ball falls past the bottom of the screen, we work out which histogram bin it landed in from its x position, add one to that bin and to the count of fallen balls, and then respawn the ball at the top of the board with zero velocity. The second pass checks every ball for collisions with the pegs, which is described in the next section.

=== Peg collisions
In the baseline implementation, peg collisions are checked after every ball has been moved. For every one of the 136 pegs, we loop over every ball and call `checkBallCollision`. If the ball is touching the peg, we find the unit vector pointing from the peg to the ball, which needs two divides. The ball is moved out to the edge of the peg along that vector so it doesn't get stuck inside, and its velocity is reflected about that vector if it is moving into the peg. Finally, the collision starts the DMA thunk sound. 

This version is easy to follow, but it is slow. Every ball is checked against every peg every frame, so the collision pass does $136 times N$ checks for $N$ balls, even though a ball can only ever be near one or two pegs. On top of that, each real collision uses a `sqrt` and two divides in floating point, which the RP2350 has to convert to and from fix15. These are the main costs we went after in the optimizations section.

To cut down the number of checks, we used the fact that the pegs are in a fixed grid. A ball can only hit a peg if their centers are closer than the ball’s radius plus the peg’s radius, which is at most 16 pixels. The rows are 19 pixels apart, so only 2 rows at most can be that close to a ball vertically. The pegs in a row are 38 pixels apart, so only the closest peg in each row can be close enough horizontally. Using the ball’s position, we divide by the peg spacing to find which rows are nearby and which peg in each row is closest. Then we look up that peg in the array and run the exact collision check on just that peg. Balls that are above the top row or below the bottom row skip the check completely. This means each ball needs at most 2 collision checks instead of 136, which made Core 1’s physics loop much faster. It was one of our first big jumps in ball count, and it was part of the round of changes that took us from 850 to 3,000 balls.

=== Board layout and histogram
The board is a triangle of 136 pegs in 16 rows. The first row has one peg and each row after it has one more, so the last row has 16. The top peg sits at the center of the screen at $(320, 100)$, and the rows are 19 px apart. Within a row, the pegs are 38 px apart, so each peg sits directly between the two pegs below it. This means a ball that bounces off a peg lands on one of the two pegs in the next row, just like a real Galton board. The peg positions are computed once at startup and stored row by row in a statically allocated array, so peg number $c$ in row $r$ is at $x = 320 + (2c - r) dot 19$ and $y = 100 + 19r$. Balls spawn above the top peg at $x = 320$, so every ball starts by hitting the first peg.

The histogram at the bottom of the screen has 17 bins, one for each gap the ball can fall through below the last row: the 15 gaps between the 16 pegs, plus one on each side. Each bin is 38 px wide, and the bins are lined up so that their edges fall directly under the pegs in the bottom row, with the middle bin centered under the top peg. When a ball falls past the bottom of the screen, the physics thread finds its bin by subtracting the left edge of the histogram from the ball's x position and dividing by the bin width, then adds one to that bin.

Each frame, the drawing thread scales the bars so that the tallest bin is 80 px high and the others are drawn in proportion to it. This way the histogram always fits under the board no matter how many balls have fallen. The count for each bin is printed above its bar. Whenever the user turns or presses the encoder, the encoder interrupt clears the histogram and the count of fallen balls, so the distribution starts over with the new settings.

=== DMA thunk sound
Each time a ball hits a peg, the speaker plays a short thunk. Since collisions can happen thousands of times a second, we didn't want the CPU to spend any time sending audio samples to the DAC. Instead, the sound is played entirely by a DMA channel, and the physics thread only has to start it.

At startup, we fill a 256-entry table with one period of a sine wave multiplied by a decaying envelope, so each period starts loud and fades out. Each entry already has the MCP4822 configuration bits for channel A in its upper 4 bits, so it is a complete 16-bit SPI word that can be sent straight to the DAC. The table is aligned to 512 bytes so that the DMA channel can use ring-buffer wrapping on its read address.

The DMA channel reads from the table and writes to the SPI data register, with the read address incrementing and the write address fixed. Instead of being paced by the SPI, it is paced by a DMA timer set to $1/3401$ of the system clock, which is about 44 kHz at 150 MHz. With the read address wrapping every 512 bytes, the channel loops through the table on its own without needing a second control channel to reset it. The channel is configured at startup but not started.

When `checkBallCollision` detects a hit, it calls `dma_chirp`, which writes a transfer count of $5 times 256 = 1280$ samples to the channel and starts it. The DMA then plays five periods of the table (about 29 ms) and stops by itself. The thunk plays on every collision, not just the first time a ball reaches a new peg. Starting the sound is a single register write, so it costs the physics thread almost nothing. If another collision happens while a thunk is still playing, the channel is already busy and the new trigger is ignored, so with many balls the thunks blend into a steady rattle instead of piling up.

=== Encoder modes and on-screen display

The user controls the simulation with the rotary encoder. Turning the knob changes a setting, and pressing it down switches which setting is being changed. Each press moves to the next mode in this order: number of balls, bounciness, gravity, and ball radius. After ball radius, it goes back to number of balls. The button uses a falling-edge interrupt.

To read the knob, we set an interrupt on the falling edge of channel A. When it fires, we read channel B. If B is high, the knob turned one way, and we add 1. If B is low, it turned the other way, and we subtract 1. Each click changes the current setting by one step. Number of balls changes by 1, from 0 up to 24,000. Bounciness changes by 0.01, from 0 to 1.00. Gravity changes by 0.01 and is allowed to go negative. With negative gravity, the balls “fall” upward and pile up at the top of the screen. Ball radius changes by 1 pixel, from 1 to 10.

Any time the user turns the knob or presses the button, the histogram and the count of fallen balls reset to zero. That way the histogram only shows balls that fell with the current settings.

The top-left corner of the screen shows the number of balls that have fallen, the seconds since boot, and the current value of each setting. Below that, it shows how long Core 1 spent on physics and how long Core 0 spent drawing in the last frame, out of the 16.67 ms budget. We used these timers to find the bottleneck while optimizing.

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
    [Radius-1 balls], [Balls shrunk to 1 px with a fast drawing path], [10,000],
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

*1-bit color.* At this point we ran out of memory, not time. The RP2350 has 520 KB of SRAM. The two VGA frame buffers at 4 bits per pixel took 2 #sym.times 153,600 = 307,200 bytes, and each ball takes 16 bytes (four fix15 numbers), so we could only fit about 12,500 balls. Since we didn't need color, we changed the VGA driver & the PIO program to use only 1 bit per pixel. Previously, each byte stored 2 pixels to allow for 4-bit color, but we wanted to compress the information of 8 pixels into 1 byte. We still had to output 4 bits worth of information per pixel to the VGA, so in the PIO program, we would take each bit from the shift register and repeat it 4 times to the VGA. This also meant that we could only output either 0000 or 1111 to the VGA, which is black or white. Previously, we were using different colors to show the user what parameter they had selected to change, but after this change, we made the text blink to indicate which entry was selected. This change shrunk each buffer to 38,400 bytes and frees 230,400 bytes, enough for about 14,400 more balls. 


*Overclock.* We raised the system clock from 150 MHz to 200 MHz. To keep the VGA timing correct, we changed the PIO clock dividers from 6 to 8 (so the PIO still runs at 25 MHz) and adjusted the delays in the RGB program.

*Things we tried and undid.* #todo[Why were these reverted?]
- Stochastic rounding
- Separate protothreads for the text and the histogram

== Testing

#figure(
  table(
    columns: (1.4fr, 1.6fr, 1.4fr),
    inset: 6pt,
    align: left,
    stroke: 0.5pt,
    table.header[*Requirement*][*Test*][*Pass criterion*],
    [Encoder rotating CW/CCW], [Rotate while watching VGA count], [Increments / decrements reliably],
    [One ball, one peg], [Drop, collide, thunk, respawn], [Audible thunk; gravity; auto-respawn],
    [16-row board $>=$ 10 balls], [Watch VGA], [All collide, thunk, respawn],
    [Live stats], [VGA overlay], [Active balls, total fallen, time since boot],
    [Histogram], [Let balls build up], [17 bins; bars fit under the board],
    [Encoder modes], [Click through modes], [VGA shows mode; rotating encoder edits that setting],
    [Setting change resets stats], [Turn encoder mid-run], [Histogram and total fallen go to 0],
    [Deadline LED], [Overload the system (increase ball count, increase radius, etc.)], [LED on only when frame $>$ 16.67 ms],
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

== Software System Diagram
#figure(
  image("figures/frame-flowchart.png", width: 90%),
  caption: [One frame of the program. Core 0 draws while Core 1 runs the physics.],
) <fig:flow>

#todo[Encoder mode cycle diagram.]


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

One thing we would change is how the screen shows which setting the user is editing. At first, we highlighted the active setting in blue. After we switched the display to 1-bit color to save memory, the screen could only show black and white, so the blue highlight showed up as white and disappeared. If we did this again, we would put an arrow/dot in front of the active setting instead. This only uses text, so it works in black and white and doesn’t cost extra memory. It would make it much easier for the user to tell which setting the knob is about to change.

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
