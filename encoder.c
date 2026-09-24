/**
 *
 * Both channels raise a GPIO interrupt on both edges. The shared
 * callback re-reads the live state of both pins and feeds the
 * (previous, current) pair into a Gray-code table: +1 for a legal
 * clockwise transition, -1 for counterclockwise, 0 for no change or
 * an illegal jump -- which is what contact bounce looks like, so the
 * zeros in the table are the debouncing.
 *
 * COM is tied to GND and A/B use internal pull-ups, so a pin reads
 * LOW when a contact zone sits underneath it, HIGH when floating.
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
 
 //a detent is the physical click you feel when you turn the knob. 
 #define TRANSITIONS_PER_DETENT 4
 
 // Index = (previous_state << 2) | current_state, where
 // state = (A << 1) | B from the raw (active-low) pin readings.
 // If the count runs backwards, swap ENC_A and ENC_B above.
 static const int8_t enc_table[16] = {
      0, -1,  1,  0,
      1,  0,  0, -1,
     -1,  0,  0,  1,
      0,  1, -1,  0
 };
 
 volatile int encoder_count = 0;
 static volatile uint8_t enc_prev_state = 0;
 
 // Read both channels in one bus access, packed as (A << 1) | B.
 static inline uint8_t read_encoder_state(void) {
     uint32_t pins = gpio_get_all();
     return (uint8_t)((((pins >> ENC_A) & 1u) << 1) | ((pins >> ENC_B) & 1u));
 }
 
 // Shared GPIO interrupt handler. Ignores both arguments: by the time
 // the ISR runs the contacts may have moved again, so re-reading live
 // state and letting the table arbitrate is cheaper and correct.
 void gpio_callback(uint gpio, uint32_t event_mask) {
     uint8_t curr = read_encoder_state();
     encoder_count += enc_table[(enc_prev_state << 2) | curr];
     enc_prev_state = curr;
 }
 
 static PT_THREAD (protothread_anim(struct pt *pt))
 {
     PT_BEGIN(pt);
 
     static char buf[16];
 
     while (1) {
         // Wait for the back buffer, then clear it. Everything visible
         // this frame must be redrawn -- nothing persists across a flip.
         PT_YIELD_UNTIL(pt, draw_start_signal());
         clearLowFrame(0, BLACK);
 
         setTextColor(WHITE);
         setTextSize(3);
         setCursor(80, 120);
         sprintf(buf, "%d", encoder_count / TRANSITIONS_PER_DETENT);
         writeString(buf);
     }
 
     PT_END(pt);
 }
 
 int main() {
     set_sys_clock_khz(150000, true);
     stdio_init_all();
     initVGA();
 
     // The encoder never drives these pins high -- COM is grounded and
     // A/B float when no contact zone is underneath -- so the pull-up
     // defines the idle level.
     gpio_init(ENC_A);
     gpio_init(ENC_B);
     gpio_set_dir(ENC_A, GPIO_IN);
     gpio_set_dir(ENC_B, GPIO_IN);
     gpio_pull_up(ENC_A);
     gpio_pull_up(ENC_B);
 
     // Seed with wherever the knob is sitting, so the first real
     // transition isn't compared against a fictitious state of 0.
     enc_prev_state = read_encoder_state();
 
     // One shared GPIO IRQ handler serves the whole pin bank, so the
     // callback is registered once and the second pin is enabled with
     // the plain variant. Both edges on both channels: rising edges
     // alone throw away half the information, including direction.
     gpio_set_irq_enabled_with_callback(ENC_A,
         GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true, &gpio_callback);
     gpio_set_irq_enabled(ENC_B,
         GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
 
     pt_add_thread(protothread_anim);
     pt_schedule_start;
 
     return 0;
 }