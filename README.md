# manage and use charateristics of files in large file systems

When using files that should be in an accessible file system, quite often I have been in a situation where

    * I couldn't find a document by name but remembered attributes like 'document' (unclear which format) with '> 12 pages' and dates from '2011 - 2015'
    * I needed to remove a lot of duplicates for sake of saving disk space but as well for cleaning up directory structures
    * searching for 'similar' files (where similiar is to be defined by content type)

Therefore, I want to implement the following three components: 

    1. database scheme that holds not only file attributes stored in a file system, but additional values such as content type, checksum, type-specific characteristics, ...
    2. script to manage such a database (import, prune, find duplicates, ...)
    3. frontend to search for files of interest

