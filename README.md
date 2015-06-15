# MOOSE Autocomplete Package

Context sensitive Atom.io autocompletion for [MOOSE Framework](http://mooseframework.org) input files. Install
[autocomplete-plus](https://github.com/atom-community/autocomplete-plus) before
installing this package.

The _MOOSE autocomplete_ plugin will automatically call your MOOSE-based app to obtain the input file syntax data.
The syntax is cached and will be rebuilt if your app is recompiled. The MOOSE-based app (or a symbolic link pointing to the executable) must be in or (an arbitrary
number of parent directory levels) above the directory of the current input file.

###Supported completions

All completions are _context sensitive_, i.e. only valid items are suggested for the current cursor position.
The following completions are provided:

* Block names and subblock names
* Block ```type``` parameters with a selection of applicable Moose objects
  * Class documentation string is shown
* Parameter names depending on the ```type``` of the current block
  * Parameter documentation string is shown
* Parameter values (also for vector parameters) for
  * Variable names for non-linear and/or auxiliary variables
  * Function names for functions explicitly defined in the ```[Functions]``` block
  * ```UserObject```, ```Postprocessor```, and ```VectorPostprocessorName``` names
  * Valid options for ```MooseEnum``` and ```MultiMooseEnum``` parameters
  * Initial support for output types
  * Boolean types
  * Pre-fill default values

###Screen shot

![in action](http://dschwen.github.io/img/autocomplete.gif)

###Changes

Check the [changelog](https://github.com/dschwen/autocomplete-moose/blob/master/CHANGELOG.md) on GitHub.
