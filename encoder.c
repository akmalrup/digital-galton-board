/**
 * ECE 4760 / 5730 - Lab 2 (Digital Galton Board)
 * Week 1: rotary encoder software interface
 *
 * Displays a number on the VGA display that increments when the
 * encoder is rotated clockwise and decrements when rotated
 * counterclockwise.
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
 */

 #include "VGA/vga16_graphics_v3.h"
 #include <stdio.h>
 #include "pico/stdlib.h"
 #include "hardware/gpio.h"
 #include "pt_cornell_rp2040_v1_4.h"
 
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
 
 static PT_THREAD (protothread_anim(struct pt *pt))
 {
     PT_BEGIN(pt);
 
     static char buf[16];
 
     while (1) {
         // Wait for the back buffer, then clear it. Everything visible
         // this frame has to be redrawn -- nothing carries over.
         PT_YIELD_UNTIL(pt, draw_start_signal());
         clearLowFrame(0, BLACK);
 
         setTextColor(WHITE);
         setTextSize(3);
         setCursor(80, 120);
         sprintf(buf, "%d", encoder_count / TRANSITIONS_PER_CLICK);
         writeString(buf);
     }
 
     PT_END(pt);
 }
 
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
 
     pt_add_thread(protothread_anim);
     pt_schedule_start;
 
     return 0;
 }