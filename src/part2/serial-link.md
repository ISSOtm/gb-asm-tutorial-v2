# Serial Link

---

**TODO:** In this lesson...
- learn about the Game Boy serial port...
	- how it works, how to use it
	- pitfalls and challenges
- build a thing, Sio Core:
	- multibyte + convenience wrapper over GB serial
	- incl. sync catchup delays, timeouts
- do something with Sio:
	- integrate/use Sio
	- ? manually choose clock provider
	- ? send some data ...
- ? build a thing, 'Packets':
	- adds data integrity test with simple checksum

---


## Running the code
To test the code in this lesson, you'll need a link cable, two Game Boys, and a way to load the ROM on both devices at once, e.g. two flash carts.
There are no special cartridge requirements -- the most basic ROM-only carts will work.

You can use any combination of Game Boy models, *provided you have the appropriate cable/adapter to connect them*.
The only thing to look out for is that a different (smaller) connector was introduced with the MGB.
So if you're connecting a DMG with a later model, make sure you have an adapter or a cable with both connectors.

<!-- TODO: Perhaps somebody can confirm if AGB (& SP?) can be used for testing? -->
<!-- You can also use an original Game Boy Advance or SP for testing purposes as they're backwards compatible. -->
<!-- The AGB introduced another connector ... you can't use an AGB link cable with the older devices, but the MGB link cable works to connect to AGB. -->

:::tip Can I just use an emulator?

Emulators should not be relied upon as a substitute for the real thing, especially when working with the serial port.
<!-- With that said, gbe-plus seems promising... -->
<!-- Also, avoid Emulicious... -->

:::


## The Game Boy serial port

---

**TODO:** about this section
- this section = crash course on GB serial port theory and operation
- programmer's mental model (not a description of the hardware implementation)

---

Communication via the serial port is organised as discrete data transfers of one byte each.
Data transfer is bidirectional, with every bit of data written out matched by one read in.
A data transfer can therefore be thought of as *swapping* the data byte in one device's buffer for the byte in the other's.

The serial port is *idle* by default.
Idle time is used to read received data, configure the port if needed, and load the next value to send.

Before we can transfer any data, we need to configure the *clock source* of both Game Boys.
To synchronise the two devices, one Game Boy must provide the clock signal that both will use.
Setting bit 0 of the **Serial Control** register (`SC`) enables the Game Boy's *internal* serial clock, and makes it the clock provider.
The other Game Boy must have its clock source set to *external* (`SC` bit 0 cleared).
The externally clocked Game Boy will receive the clock signal via the link cable.

Before a transfer, the data to transmit is loaded into the **Serial Buffer** register (`SB`).
After a transfer, the `SB` register will contain the received data.

When ready, the program can set bit 7 of the `SC` register in order to *activate* the port -- instructing it to perform a transfer.
While the serial port is *active*, it sends and receives a data bit on each serial clock pulse.
After 8 pulses (*8 bits!*) the transfer is complete -- the serial port deactivates itself, and the serial interrupt is requested.
Normal execution continues while the serial port is active: the transfer will be performed independently of the program code.

---

**TODO:** something about the challenges posed...
- GB serial is not "unreliable"... But it's also "not reliable"...
- some notable things for reliable communication that GB doesn't provide:
	- connection detection, status: can't be truly solved in software, work around with error detection
	- delivery report / ACK: software can make improvements with careful design
	- error detection: software implementation can be effective

---


## Sio
Let's start building **Sio**, a serial I/O guy.

---

**TODO:** Create a file, sio.asm? (And complicate the build process) ... Just stick it in main.asm?

---

First, define the constants that represent Sio's main states/status:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-status-enum}}
{{#include ../../unbricked/serial-link/sio.asm:sio-status-enum}}
```

Add a new WRAM section with some variables for Sio's state:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-state}}
{{#include ../../unbricked/serial-link/sio.asm:sio-state}}
```

We'll discuss each of these variables as we build the features that use them.

Add a new code section and an init routine:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-impl-init}}
{{#include ../../unbricked/serial-link/sio.asm:sio-impl-init}}
```


### Buffers
The buffers are a pair of temporary storage locations for all messages sent or received by Sio.
There's a buffer for data to transmit (Tx) and one for receiving data (Rx).
Both buffers will be the same size, which is set via a constant:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-buffer-defs}}
{{#include ../../unbricked/serial-link/sio.asm:sio-buffer-defs}}
```

:::tip

Blocks of memory can be allocated using `ds N`, where `N` is the size of the block in bytes.
For more about `ds`, see [Statically allocating space in RAM](https://rgbds.gbdev.io/docs/rgbasm.5#Statically_allocating_space_in_RAM) in the rgbasm language manual.

:::

Define the buffers, each in its own WRAM section:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-buffers}}
{{#include ../../unbricked/serial-link/sio.asm:sio-buffers}}
```

:::tip ALIGN

For the purpose of this lesson, `ALIGN[8]` causes the section to start at an address with a lower byte of zero.
The reason that these sections are *aligned* like this is explained below.

If you want to learn more -- *which is by no means required to continue this lesson* -- the place to start is the [SECTIONS](https://rgbds.gbdev.io/docs/rgbasm.5#SECTIONS) section in the rgbasm language documenation.

:::

Each buffer is aligned to start at an address with a low byte of zero.
This makes building a pointer to the element at index `i` trivial, as the high byte of the pointer is constant for the entire buffer, and the low byte is simply `i`.

The variable `wSioBufferOffset` holds the current location within *both* data buffers and can be used as an offset/index and directly in a pointer.

The result is a significant reduction in the amount of work required to access the data and manipulate offsets of both buffers.


### Core implementation
<!-- TransferStart -->
Below `SioInit`, add a function to start a multibyte transfer of the entire data buffer:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-start-transfer}}
{{#include ../../unbricked/serial-link/sio.asm:sio-start-transfer}}
```

To initialise the transfer, start from buffer offset zero, set the transfer count, and switch to the `SIO_ACTIVE` state.
The first byte to send is loaded from `wSioBufferTx` before a jump to the next function starts the first transfer immediately.

<!-- PortStart -->
Activating the serial port is a simple matter of setting bit 7 of `rSC`, but we need to do a couple of other things at the same time, so add a function to bundle it all together:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-port-start}}
{{#include ../../unbricked/serial-link/sio.asm:sio-port-start}}
```

The first thing `SioPortStart` does is something called the "catchup delay", but only if the internal clock source is enabled.

:::tip Delay? Why?

When a Game Boy serial port is active, it will transfer a data bit whenever it detects clock pulse.
When using the external clock source, the active serial port will wait indefinitely -- until the externally provided clock signal is received.
But when using the internal clock source, bits will start getting transferred as soon as the port is activated.
Because the internally clocked device can't wait once activated, the catchup delay is used to ensure the externally clocked device activates its port first.

:::

To check if the internal clock is enabled, read the serial port control register (`rSC`) and check if the clock source bit is set.
We test the clock source bit by *anding* with `SCF_SOURCE`, which is a constant with only the clock source bit set.
The result of this will be `0` except for the clock source bit, which will maintain its original value.
So we can perform a conditional jump and skip the delay if the zero flag is set.
The delay itself is a loop that wastes time by doing nothing -- `nop` is an instruction that has no effect -- a number of times.

To start the serial port, the constant `SCF_START` is combined with the clock source setting (still in `a`) and the updated value is loaded into the `SC` register.

Finally, the timeout timer is reset by loading the constant `SIO_TIMEOUT_TICKS` into `wSioTimer`.

:::tip Timeouts

We know that the serial port will remain active until it detects eight clock pulses, and performs eight bit transfers.
A side effect of this is that when relying on an *external* clock source, a transfer may never end!
This is most likely to happen if there is no other Game Boy connected, or if both devices are set to use an external clock source.
To avoid having this quirk become a problem, we implement *timeouts*: each byte transfer must be completed within a set period of time or we give up and consider the transfer to have failed.

:::

We'd better define the constants that set the catchup delay and timeout duration:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-port-start-defs}}
{{#include ../../unbricked/serial-link/sio.asm:sio-port-start-defs}}
```

<!-- Tick -->
Implement `SioTick` to update the timeout and `SioAbort` to cancel the ongoing transfer:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-tick}}
{{#include ../../unbricked/serial-link/sio.asm:sio-tick}}
```

Check that a transfer has been started, and that the clock source is set to *external*.
Before *ticking* the timer, check that the timer hasn't already expired with `and a, a`.
Do nothing if the timer value is already zero.
Decrement the timer and save the new value before jumping to `SioAbort` if new value is zero.

<!-- PortEnd -->
The last part of the core implementation handles the end of a transfer:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-port-end}}
{{#include ../../unbricked/serial-link/sio.asm:sio-port-end}}
```

---

**TODO:** walkthrough SioPortEnd

this one is a little bit more involved...

- check that Sio is in the **ACTIVE** state before continuing
- use `ld a, [hl+]` to access `wSioState` and advance `hl` to `wSioCount`
- update `wSioCount` using `dec [hl]`
	- which you might not have seen before?
	- this works out a bit faster than reading number into `a`, decrementing it, storing it again

- NOTE: at this point we are avoiding using opcodes that set the zero flag as we want to check the result of decrementing `wSioCount` shortly.

- construct a buffer Rx pointer using `wSioBufferOffset`
	- load the value from wram into the `l` register
	- load the `h` register with the constant high byte of the buffer Rx address space

- grab the received value from `rSB` and copy it to the buffer Rx
	- we need to increment the buffer offset ...
	- `hl` is incremented here but we know only `l` will be affected because of the buffer alignment
	- the updated buffer pointer is stored

- now we check the transfer count remaining
	- the `z` flag was updated by the `dec` instruction earlier -- none of the instructions in between modify the flags.

- if the count is more than zero (i.e. more bytes to transfer) start the next byte transfer
	- construct a buffer Tx pointer in `hl` by setting `h` to the high byte of the buffer Tx address. keep `l`, which has the updated buffer position.
	- load the next tx value into `rSB` and activate the serial port!

- otherwise the count is zero, we just completed the final byte transfer, so set `SIO_DONE` and return.

---

`SioPortEnd` must be called once after each byte transfer.
To do this we'll use the serial interrupt:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-serial-interrupt-vector}}
{{#include ../../unbricked/serial-link/sio.asm:sio-serial-interrupt-vector}}
```

---

**TODO:** explain something about interrupts? but don't be weird about it, I guess...

---


## Using Sio

---

**TODO:**

/// initialise Sio
Before doing anything else with Sio, `SioInit` needs to be called.

```rgbasm
	call SioInit

	; enable interrupts!
	ei
```

/// update Sio every frame...
```rgbasm
	call SioTick
```

/// set clock source
```rgbasm
	ld a, SCF_SOURCE
	ldh [rSC], a
```

/// do handshakey thing?
/// whoever presses KEY attempts to do a transfer as the clock provider
```rgbasm
```

---
