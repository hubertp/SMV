# Known issues in current SMV version

## Hive table updates
SMV can not detect changes in Hive Table inputs.  There is not automatic way for SMV to determine the last modification time of a hive table.  Therefore, downstream modules that depend on a hive table will not be recomputed when the hive table is modified.

See [SMV issue 307](https://github.com/TresAmigosSD/SMV/issues/307) for details.


## CSV parsing is line based
SMV assumes CSV files use new-line as the record separator.  While SMV utilizes a library that can handle different record separators, the CSV file is split into multiple partitions along line boundaries when stored on HDFS.  So potentially, the CSV parser will not see the entire line for lines that contain a new-line if they are split across HDFS block boundary.

See [SMV issue 320](https://github.com/TresAmigosSD/SMV/issues/320) for details.
