# Serial Link

---

**TODO:** In this lesson...
- learn how to control the Game Boy serial port from code
- build a wrapper over the low-level serial port interface
- implement high-level features to enable reliable data transfers

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

:::


## The Game Boy serial port

:::tip Information overload

This section is intended as a reasonably complete description of the Game Boy serial port, from a programming perspective.
There's a lot of information packed in here and you don't need to absorb it all to continue.

:::

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


## Sio

<!-- /// Connectivity features tend to have a multiplicative effect on a developer's workload, particularly in testing and debugging.
/// This is why we're going to work outside of the unbricked project for a while.
/// create a separate folder for this program? -->

/// Let's start building **Sio**, our serial I/O system.
/// Create a new source file called `sio.asm`. ... reuseable code ... & avoid gigantic `main.asm`

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

All this short routine really *does* is `call SioPortEnd`.
But because this is an interrupt handler we have to do a little dance to prevent *bad things* from happening.
We need to preserve the values in the registers that will be modified by `SioPortEnd`, `af` and `hl`.
/// make sure the registers are in the same state as when the interrupt occured so that when the interrupted code is resumed, it can continue as if nothing happened.
*The stack* is the perfect way to do this.
`push` copies the value from the register to the top of the stack and `pop` takes the top value off of the stack and moves it to the register.
Note that a stack is a first-in first-out (FIFO) container, so we push `af` then `hl` -- leaving `hl` on the top -- and pop `hl` then `af`.

:::tip We interrupt this broadcast to briefly explain what interrupts are

An interrupt is a way to run a certain piece of code when an external event occurs.
Interrupts are requested by *peripherals* (hardware connected to the CPU) and the CPU literally interrupts whatever it was doing to go an execute some different code instead.
In this case, the event is the serial port counting to eight (meaning a whole byte was transferred), and the code that will be executed is whatever is at memory address `$58` -- the routine above.

:::


### A little protocol

Before diving into (more) implementation, let's take a minute to describe a *protocol*.
A protocol is a set of rules that govern communication.

/// Everything is packets.
/// Packets: small chunks of data with rudimentary error detection

For reliable data transfer, alternate between two message types:
protocol metadata in *SYNC* packets, and application data in *DATA* packets.
DATA packets are required to include a sequential message ID -- the rest is up to the application.
SYNC packets include the ID of the most recently received DATA packet.

Packet integrity can be tested on the receiving end using a checksum.
Damaged packets of either type are discarded.
Successful delivery of a DATA packet is acknowledged when its ID is included in a SYNC packet.
The sender should retransmit the packet if successful delivery is not acknowledged.

There's one more thing our protocol needs: some way to get both devices on the same page and kick things off.
We need a *handshake* that must be completed before doing anything else.
This is a simple sequence that checks that there is a connection and tests that the connection is working.
The handshake can be performed in one of two roles: *A* or *B*.
To be successful, one peer must be *A* and the other must be *B*.
Which role to perform is determined by the clock source setting of the serial port.
In each exchange, each peer sends a number associated with its role and expects to receive a number associated with the other role.
If an unexpected value is received, or something goes wrong with the transfer, that handshake attempt is aborted.


### /// SioPacket

We'll implement some functions to facilitate constructing, sending, receiving, and checking packets.
The packet functions will operate on the existing serial data buffers.

The packets follow a simple structure: starting with a header containing a magic number and the packet checksum, followed by the payload data.
The magic number is a constant that marks the start of a packet.

At the top of `sio.asm` define some constants:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-packet-defs}}
{{#include ../../unbricked/serial-link/sio.asm:sio-packet-defs}}
```

/// function to call to start building a new packet:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-packet-prepare}}
{{#include ../../unbricked/serial-link/sio.asm:sio-packet-prepare}}
```

/// returns packet data pointer in `hl`

/// After calling `SioPacketTxPrepare`, the payload data can be added to the packet.

Once the desired data has been copied to the packet, the checksum needs to be calculated before the packet can be transferred.
We call this *finalising* the packet and this is implemented in `SioPacketTxFinalise`:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-packet-finalise}}
{{#include ../../unbricked/serial-link/sio.asm:sio-packet-finalise}}
```

/// call `SioPacketChecksum` to calculate the checksum and write the result to the packet.

/// a function to perform the checksum test when receiving a packet, `SioPacketRxCheck`:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-packet-check}}
{{#include ../../unbricked/serial-link/sio.asm:sio-packet-check}}
```

/// Checks that the packet begins with the magic number `SIO_PACKET_START`, before checking the checksum.
/// For convenience, a pointer to the start of packet data is returned in `hl`.

/// Finally, implement the checksum:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/sio.asm:sio-checksum}}
{{#include ../../unbricked/serial-link/sio.asm:sio-checksum}}
```

:::tip

The checksum implemented here has been kept very simple for this tutorial.
It's probably not very suitable for real-world projects.

:::


## /// Using Sio

/// Because we have an extra file (sio.asm) to compile now, the build commands will look a little different:
```console
$ rgbasm -L -o sio.o sio.asm
$ rgbasm -L -o main.o main.asm
$ rgblink -o unbricked.gb main.o sio.o
$ rgbfix -v -p 0xFF unbricked.gb
```

<!-- "Link" -->
/// serial link features: *Link*

/// tiles

/// defs

<!-- LinkInit -->
/// one function to initialise basic serial link state.

/// Implement `LinkInit`:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:link-init}}
{{#include ../../unbricked/serial-link/main.asm:link-init}}
```

Calling `SioInit` prepares Sio for use, except for one thing: **e**nabling **i**nterrupts with the `ei` instruction.

:::tip

If interrupts must be enabled for Sio to work fully, you might be wondering why we don't just do it in `SioInit`.
Sio is in control of the serial interrupt, but `ei` enables interrupts globally.
Other interrupts may be in use by other parts of the code, which are clearly outside of Sio's responsibility.

/// Sio doesn't enable or disable interrupts because side effects ...

/// [Interrupts](https://gbdev.io/pandocs/Interrupts.html)

:::

Note that `LinkReset` starts part way through `LinkInit`.
This way the two functions can share code with zero overhead and `LinkReset` can be called without performing the startup initialisation again.
This pattern is often referred to as *fallthrough*: `LinkInit` *falls through* to `LinkReset`.

Call the init routine once before the main loop starts:

```rgbasm
	call LinkInit
```

/// `LinkTx`, alternate between sending the two types of packet:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:link-send-message}}
{{#include ../../unbricked/serial-link/main.asm:link-send-message}}
```

/// Implement `LinkUpdate`:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:link-update}}
{{#include ../../unbricked/serial-link/main.asm:link-update}}
```

/// reset the demo if the B button is pressed

/// update Sio every frame

In the `LINK_INIT` state, do handshake until its done.
Once the handshake is complete, change to the `LINK_UP` state.

/// In the `LINK_UP` state, ...

When a transfer has completed (`SIO_DONE`), process the received data in `LinkRx`:

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:link-receive-message}}
{{#include ../../unbricked/serial-link/main.asm:link-receive-message}}
```

/// We flush Sio's state (set it to `SIO_IDLE`) here so ... LinkTx ... next update...

Check that we received a packet and its checksum matches.
If the packet integrity test comes back negative, increment the inbound transmission errors counter.

:::tip

/// This class of error -- which we're calling a *transmission errors* -- are very significant.
/// assuming code works -- & have reason to believe it does -- this means the data was damaged during transmission, if a valid packet was sent

/// You might want to do something a bit more sophisticated than counting errors in a real-world application.

:::

/// with the packet checking out OK, move on to process the message it contains
/// jump to the appropriate handler ...
/// if the msg type is unknown/unexpected, increment the message/protocol error counter.

/// SYNC messages...

---

/// TEST_DATA messages...

---


### Implement the handshake protocol

/// Establish contact by trading magic numbers

/// Define the codes each device will send:
```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:handshake-codes}}
{{#include ../../unbricked/serial-link/main.asm:handshake-codes}}
```

///
```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:handshake-state}}
{{#include ../../unbricked/serial-link/main.asm:handshake-state}}
```

/// Routines to begin handshake sequence as either the internally or externally clocked device.

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:handshake-begin}}
{{#include ../../unbricked/serial-link/main.asm:handshake-begin}}
```

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:handshake-update}}
{{#include ../../unbricked/serial-link/main.asm:handshake-update}}
```

The handshake can be forced to restart in the clock provider role by pressing START.
This is included as a fallback and manual override for the automatic role selection implemented below.

If a transfer is completed, process the received data by jumping to `HandshakeMsgRx`.

If the serial port is otherwise inactive, (re)start the handshake.
To automatically determine which device should be the clock provider, we check the lowest bit of the DIV register.
This value increments at around 16 kHz which, for our purposes and because we only check it every now and then, is close enough to random.

```rgbasm,linenos,start={{#line_no_of "" ../../unbricked/serial-link/main.asm:handshake-xfer-complete}}
{{#include ../../unbricked/serial-link/main.asm:handshake-xfer-complete}}
```

Check that a packet was received and that it contains the expected handshake value.
The state of the serial port clock source bit is used to determine which value to expect -- `SHAKE_A` if set to use an external clock and `SHAKE_B` if using the internal clock.
If all is well, decrement the `wHandshakeState` counter.
If the counter is zero, there is nothing left to do.
Otherwise, more exchanges are required so start the next one immediately.

:::tip

This is a trivial example of a handshake protocol.
In a real application, you might want to consider:
- using a longer sequence of codes as a more unique app identifier
- sharing more information about each device and negotiating to decide the preferred clock provider

:::
