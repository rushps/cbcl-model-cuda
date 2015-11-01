## Introduction ##
This project provides a CUDA implementation of the matlab code available [here](http://code.google.com/p/cbcl-model-matlab/). Description of the algorithms can be found at [CBCL](http://cbcl.mit.edu)'s website. The ventral stream model consists of a hierarchical (sequential) stages of S (feature detection) and C (pooling) type computation. The 'S' and 'C' refers to **simple** cells and **complex** cells found in the visual system.

Each 'S' stage operates on the previous 'C' stage using a bank of feature detectors. Thus each feature detection stage can be computed independently (task-parallel operation). Alternatively, for each feature detection operation, each output pixel can be computed idependently (data-parallel operation). The former is suited for a multi-threaded/MPI approach. We adopt the latter approach to conform to SIMD mode of a GPU.

## Release Notes ##
  * Release 0: Works only on MAC/linux
  * Release 1: Works on windows as well. Includes `*`.sln files to build on windows
  * Release 1.1: Removes redundant memcopy between stages, uses 2D memory layout and computes only valid pixels
  * Release 1.2: Uses loop unrolling.