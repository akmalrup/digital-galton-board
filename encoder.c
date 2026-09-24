/**
 * ECE 4760 / 5730 - Lab 2 (Digital Galton Board)
 * Week 1: rotary encoder software interface + VGA animation
 *
 * Merged demo:
 *  - Displays rotary encoder position on the VGA display
 *    (increments clockwise, decrements counterclockwise)
 *  - Animates two balls bouncing inside an arena box using dual-core
 *    protothreads (boid 0 on core 0, boid 1 on core 1)
 *  - Serial console interface allows changing ball color (1-15)
 *
 * HARDWARE CONNECTIONS
 *  - GPIO 14 ---> Encoder channel A
 *  - GPIO 15 ---> Encoder channel B
 *  - GND     ---> Encoder COM
 *
 *  - GPIO 16 ---> VGA Hsync
 *  - GPIO 17 ---> VGA Vsync
 *  - GPIO 18 ---> VGA Green lo-bit --> 470 ohm resistor --> VGA_Green
 *  - GPIO 19 ---> VGA Green hi-bit --> 330 ohm resistor --> VGA_Green
 *  - GPIO 20 ---> 330 ohm resistor ---> VGA-Blue
 *  - GPIO 21 ---> 330 ohm resistor ---> VGA-Red
 *  - RP2040 GND ---> VGA-GND
 *
 * RESOURCES USED
 *  - PIO state machines 0, 1, and 2 on PIO instance 0
 *  - DMA channels (2, by claim mechanism)
 *  - 153.6 kBytes of RAM (for pixel color data)
 *  - GPIO interrupts on pins 14 and 15 for rotary encoder
 *  - Core 0 and Core 1 via Pico multicore library
 */

// Include the VGA graphics library
#include "VGA/vga16_graphics_v3.h"

// Include standard libraries
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

// Include Pico libraries
#include "pico/stdlib.h"
#include "pico/divider.h"
#include "pico/multicore.h"
#include "pico/sync.h"

// Include hardware libraries
#include "hardware/pio.h"
#include "hardware/dma.h"
#include "hardware/clocks.h"
#include "hardware/pll.h"
#include "hardware/gpio.h"

// Include protothreads
#include "pt_cornell_rp2040_v1_4.h"

// === Rotary Encoder Definitions ====================================
#define ENC_A 14
#define ENC_B 15

// One physical click of the knob produces one full electrical cycle,
// which is four transitions. Turn the knob exactly one click with this
// set to 1 to check what your encoder actually does.
#define TRANSITIONS_PER_CLICK 4

// The encoder has four electrical positions. COM is grounded and the
// pins have pull-ups, so a pin reads LOW when a contact zone shorts it
// to COM, and HIGH when it is floating.
#define BOTH_SHORTED  0   // A low,  B low
#define A_SHORTED     1   // A low,  B high
#define B_SHORTED     2   // A high, B low
#define NEITHER       3   // A high, B high

// Rotating one click clockwise walks through the positions in this
// order:  NEITHER -> A_SHORTED -> BOTH_SHORTED -> B_SHORTED -> NEITHER
// Counterclockwise is the same sequence in reverse.

volatile int encoder_count = 0;
static int previous_position = NEITHER;

// Read both pins and combine them into a single position number 0-3.
// Bit 1 is channel A, bit 0 is channel B.
static int read_encoder(void) {
    int a = gpio_get(ENC_A);
    int b = gpio_get(ENC_B);
    return (a << 1) | b;
}

// This runs every time either encoder pin changes, in either direction.
void gpio_callback(uint gpio, uint32_t event_mask) {
    int current_position = read_encoder();

    // If nothing actually changed, the contacts are just bouncing.
    // Ignore it.
    if (current_position == previous_position) {
        return;
    }

    // Figure out which way we moved by looking at where we came from
    // and where we ended up. Anything that isn't one of these eight
    // legal moves is noise, and we ignore it.
    if (previous_position == NEITHER) {
        if      (current_position == A_SHORTED)    encoder_count++;
        else if (current_position == B_SHORTED)    encoder_count--;
    }
    else if (previous_position == A_SHORTED) {
        if      (current_position == BOTH_SHORTED) encoder_count++;
        else if (current_position == NEITHER)      encoder_count--;
    }
    else if (previous_position == BOTH_SHORTED) {
        if      (current_position == B_SHORTED)    encoder_count++;
        else if (current_position == A_SHORTED)    encoder_count--;
    }
    else if (previous_position == B_SHORTED) {
        if      (current_position == NEITHER)      encoder_count++;
        else if (current_position == BOTH_SHORTED) encoder_count--;
    }

    previous_position = current_position;
}

// === Fixed point macros ============================================
typedef signed int fix15 ;
#define multfix15(a,b) ((fix15)((((signed long long)(a))*((signed long long)(b)))>>15))
#define float2fix15(a) ((fix15)((a)*32768.0)) // 2^15
#define fix2float15(a) ((float)(a)/32768.0)
#define absfix15(a) abs(a) 
#define int2fix15(a) ((fix15)(a << 15))
#define fix2int15(a) ((int)(a >> 15))
#define char2fix15(a) (fix15)(((fix15)(a)) << 15)
#define divfix(a,b) (fix15)(div_s64s64( (((signed long long)(a)) << 15), ((signed long long)(b))))

// Wall detection
#define hitBottom(b) (b>int2fix15(380))
#define hitTop(b) (b<int2fix15(100))
#define hitLeft(a) (a<int2fix15(100))
#define hitRight(a) (a>int2fix15(540))

// The color of the boid
char color = WHITE ;

typedef struct {
  fix15 x ;
  fix15 y ;
  fix15 vx ;
  fix15 vy ;
} boid_t ;

typedef struct {
  fix15 x ;
  fix15 y ;
} peg_t;

// Boid on core 0
boid_t boid0 ;

// Boid on core 1
boid_t boid1 ;

// Create a semaphore
semaphore_t draw_semaphore ;

// Create a boid
void spawnBoid(boid_t* b, int direction)
{
  // Start in center of screen
  b->x = int2fix15(320) ;
  b->y = int2fix15(240) ;
  // Choose left or right
  if (direction) b->vx = int2fix15(3) ;
  else b->vx = int2fix15(-3) ;
  // Moving down
  b->vy = int2fix15(1) ;
}

// Draw the boundaries
void drawArena() {
  drawVLine(100, 100, 280, WHITE) ;
  drawVLine(540, 100, 280, WHITE) ;
  drawHLine(100, 100, 440, WHITE) ;
  drawHLine(100, 380, 440, WHITE) ;
}

// Detect wallstrikes, update velocity and position
void wallsAndEdges(boid_t* b)
{
  // Reverse direction if we've hit a wall
  if (hitTop(b->y)) {
    b->vy = (-b->vy) ;
    b->y  = (b->y + int2fix15(5)) ;
  }
  if (hitBottom(b->y)) {
    b->vy = (-b->vy) ;
    b->y  = (b->y - int2fix15(5)) ;
  } 
  if (hitRight(b->x)) {
    b->vx = (-b->vx) ;
    b->x  = (b->x - int2fix15(5)) ;
  }
  if (hitLeft(b->x)) {
    b->vx = (-b->vx) ;
    b->x  = (b->x + int2fix15(5)) ;
  } 

  // Update position using velocity
  b->x = b->x + b->vx ;
  b->y = b->y + b->vy ;
}

// ==================================================
// === User serial input thread
// ==================================================
static PT_THREAD (protothread_serial(struct pt *pt))
{
    PT_BEGIN(pt);
    // stores user input
    static int user_input ;
    // wait for 1 sec
    PT_YIELD_usec(1000000) ;
    // announce the threader version
    sprintf(pt_serial_out_buffer, "Protothreads RP2040 v1.4\n\r");
    // non-blocking write
    serial_write ;
    while(1) {
        // print prompt
        sprintf(pt_serial_out_buffer, "input a number in the range 1-15: ");
        // non-blocking write
        serial_write ;
        // spawn a thread to do the non-blocking serial read
        serial_read ;
        // convert input string to number
        sscanf(pt_serial_in_buffer,"%d", &user_input) ;
        // update boid color
        if ((user_input > 0) && (user_input < 16)) {
          color = (char)user_input ;
        }
    } // END WHILE(1)
  PT_END(pt);
} // serial thread

// ==================================================
// === Animation & display on core 0
// ==================================================
static PT_THREAD (protothread_anim(struct pt *pt))
{
    // Mark beginning of thread
    PT_BEGIN(pt);

    static char buf[16];

    // Spawn a boid
    spawnBoid(&boid0, 0);

    while(1) {
      // Wait for the signal that the buffer's changed
      PT_YIELD_UNTIL(pt, draw_start_signal()) ;
      // Clear the buffer
      clearLowFrame(0, BLACK);
      // Signal core 1 that it can start drawing
      PT_SEM_SDK_SIGNAL(pt, &draw_semaphore) ;
      // Update boid's position and velocity
      wallsAndEdges(&boid0) ;
      // Draw the boid at its new position
      fillCircle(fix2int15(boid0.x), fix2int15(boid0.y), 15, color); 
      // Draw the boundaries
      drawArena() ;

      // Draw the encoder count in the margin above the arena box (y < 100)
      setTextColor(WHITE);
      setTextSize(3);
      setCursor(80, 40);
      sprintf(buf, "%d", encoder_count / TRANSITIONS_PER_CLICK);
      writeString(buf);
     // NEVER exit while
    } // END WHILE(1)
  PT_END(pt);
} // animation thread

// ==================================================
// === Animation on core 1
// ==================================================
static PT_THREAD (protothread_anim1(struct pt *pt))
{
    // Mark beginning of thread
    PT_BEGIN(pt);

    // Spawn a boid
    spawnBoid(&boid1, 1);

    while(1) {
      // Wait for the signal from core 0
      PT_SEM_SDK_WAIT(pt, &draw_semaphore) ;
      // Update boid's position and velocity
      wallsAndEdges(&boid1) ;
      // Draw the boid at its new position
      fillCircle(fix2int15(boid1.x), fix2int15(boid1.y), 15, color); 
     // NEVER exit while
    } // END WHILE(1)
  PT_END(pt);
} // animation thread 1

// ========================================
// === core 1 main -- started in main below
// ========================================
void core1_main(){
  // Add animation thread
  pt_add_thread(protothread_anim1);
  // Start the scheduler
  pt_schedule_start ;
}

// ========================================
// === main
// ========================================
int main() {
    set_sys_clock_khz(150000, true);
    stdio_init_all();
    initVGA();

    // The encoder never drives these pins high. COM is grounded, and
    // A and B float when no contact zone is underneath them, so the
    // pull-ups are what make a floating pin read as HIGH.
    gpio_init(ENC_A);
    gpio_init(ENC_B);
    gpio_set_dir(ENC_A, GPIO_IN);
    gpio_set_dir(ENC_B, GPIO_IN);
    gpio_pull_up(ENC_A);
    gpio_pull_up(ENC_B);

    // Start from wherever the knob is actually sitting right now.
    previous_position = read_encoder();

    // Interrupt on both rising and falling edges of both pins, because
    // we need to see all four transitions of a click. There is a single
    // shared GPIO interrupt handler for all pins, so the callback is
    // registered once and the second pin is enabled separately.
    gpio_set_irq_enabled_with_callback(ENC_A,
        GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true, &gpio_callback);
    gpio_set_irq_enabled(ENC_B,
        GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);

    // Initialize the semaphore
    // Arguments: pointer to sem, initial count, max count
    sem_init(&draw_semaphore, 0, 1);

    // Start core 1 
    multicore_reset_core1();
    multicore_launch_core1(&core1_main);

    // Add threads on core 0
    pt_add_thread(protothread_serial);
    pt_add_thread(protothread_anim);

    // Start scheduler on core 0
    pt_schedule_start;

    return 0;
}