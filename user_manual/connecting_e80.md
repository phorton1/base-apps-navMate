# navMate User Manual - Connecting an E-Series

**[Home](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**[Organizing Data](organizing_your_data.md)** --
**[Copy, Cut & Paste](copy_cut_paste.md)** --
**[Multi-Editor](winMultiEditor.md)** --
**[Import & Export](import_export.md)** --
**[FSH Files](winFSH.md)** --
**Connecting an E-Series** --
**[Using Your E-Series](using_e80.md)**

Everything so far works with navMate on its own. This chapter, and the next, are for owners of
a Raymarine **E-Series** plotter (E80 / E120) who want navMate and the plotter to talk to each
other. If you do not have one, you can skip both.

Connecting is a one-time setup: a cable between your computer and the plotter, and a short
network step that navMate helps you through.

## The three ways to connect

How you connect depends on the gear you already have. There are three common situations -- all
of which end with your computer talking to the plotter:

![Three ways to connect your computer to the E-Series plotter](images/connection_options.svg)

- **No existing cable** -- the simplest case. Run a single standard Ethernet cable straight from
  the plotter to your computer. Modern computers sort out the wiring automatically, so an
  ordinary "straight-through" cable is all you need.
- **Existing router** -- if your boat already has a network (most often the old Raymarine
  network switch), plug both the plotter and your computer into it; they find each other
  through it.
- **Crossover cable** -- if you have an old *crossover* cable left over from wiring two marine
  devices directly together, replace it with a standard cable and a switch. The diagram marks
  this case so you know to swap it out.

## The network step

A plotter and a computer will not talk until they are on the same network "address range," and
setting that up by hand is fiddly. navMate's **E-Series connection setup** is designed to do it
for you: it listens for your plotter on the cable, reads its address, and gets your computer's
network adapter onto the matching range -- so there are no IP numbers to puzzle over.

<!-- [SCREENSHOT] images/e80_connect_setup.png -- the in-app E-Series connection setup after it
     has found a plotter and is ready to configure the network -->

## Confirming the connection

Open the **E80 window** with **View -> E80**. Once your computer and the plotter are on the same
network, the plotter's own waypoints, routes, groups, and tracks appear there, ready to work
with -- which is the subject of the [next chapter](using_e80.md). If the window is empty, choose
**E80 -> Refresh E80-DB** to read the plotter's current contents.

> **Tip:** make sure the plotter is powered on and fully started up before you connect -- give it
> the minute or so it needs to finish booting.

**Next:** [Using Your E-Series](using_e80.md)
