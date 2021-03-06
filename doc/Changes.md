
# Recent changes

There is quite a lot of changes since the latest release from the original LetsMT! project. Here are some of the changes in the software and API.


* we now support git as the default backend
* batch jobs are now handled with SLURM (forget about gridengine)
* Apache Tika is updated and uses now version 1.18 and runs via a server
* UDPipe is integrated for sentence splitting (and more in the future)
* pdf2xml is integrated as pdf import method `combined` (but this is VERY slow!)
* experimental sentence alignment interface (ISA)
* support of additional commands via the job API and run: tokenize, parse, wordalign, make_tmx
* import now automatically creates TMX files as well


## Changes to the storage API

* commit revision is set to HEAD i git backend as a default; the real revision hash number is show if you add `rev=show` to a GET reques; the revision history is shown when the argument is set to 'history':

```
$LETSMT_CONNECT -X GET "$LETSMT_URL/storage/corpus/user/xml/file.xml?uid=user&rev=history"
```


* downloading data from URL's: Now it is possible to give a url in the request to download a file directly from the webto store in the repository. For example, to download `http://spiegel.de` to a repository you can run:

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/storage/corpus/user/uploads/html/spiegel.de/index.html?uid=user&action=import&url=http://www.spiegel.de"
```

* listing storages checks now whether there is a readable branch for the selected user (before all slots are always listed); for example, to list all slots that have a readable branch for user `user1` do:

```
 $LETSMT_CONNECT -X GET "$LETSMT_URL/storage?uid=user1"
```

* use special user `admin` for listing all slots in the database:

```
 $LETSMT_CONNECT -X GET "$LETSMT_URL/storage?uid=admin"
```

* send resources by e-mail (zip archives or plain files):

```
$LETSMT_CONNECT -X GET "$LETSMT_URL/storage/corpus/user/xml/en/test.html?uid=user&action=download&email=name@domain.org"
$LETSMT_CONNECT -X GET "$LETSMT_URL/storage/corpus/user/xml/en/test.html?uid=user&action=download&archive=no&email=name@domain.org"
```



## Changes to the job API

* create MD5 signatures (in case it didn't work during crawling)

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/uploads/crawl2019-Mar-10.tar.gz?uid=user&run=make_md5"
```

* list all jobs in the SLURM job queue:

```
$LETSMT_CONNECT -X GET "$LETSMT_URL/job?uid=user1"
```

NEW: this now only lists the jobs of user `user1`. If `uid=admin` then it will list all jobs in the queue for all users.

* new commands: parse and wordalign; for specific files:

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/xml/en/4.xml?uid=user&run=parse"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/xml/en-sv/4.xml?uid=user&run=wordalign"
```

* for all files in a subtree:

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/opustest2/user/xml?uid=user&run=parse"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/xml/en-sv?uid=user&run=wordalign"
```


* added: `run=reimport`: The normal import will now only do things to files that have not yet been imported. In order to overwrite existing imports, you now have to use the command `reimport`:

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/uploads/files.tar.gz?uid=user1&run=reimport"
```

For tar- and zip-files: This also checks whether there were files from the archive that failed to be imported. Normal import will try to import them again (skipping all files that have successfully been imported before). `reimport` resets the status of all files and re-imports all from scratch!


* align jobs for selected file pairs: add parameter `trg` to specify target file to be aligned

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/xml/fi/2.html.xml?uid=user1&trg=xml/sv/2.html.xml&run=align"
```

* align jobs for alignment candidates (the ones detected by import processes or `detect_translations` or `detect_unaligned`) for specific resources or for entire subtrees:

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/xml/en/2.html.xml?uid=user1&run=align_candidates"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/xml/fi?uid=user1&run=align_candidates"
```

* try to find parallel documents by running the commands `detect_translations` (all potentially parallel documents including the ones that are already aligned) or `detect_unaligned` (potentially parallel documents that are not yet aligned):

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/xml/en?uid=user1&run=detect_translations"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/xml/fi?uid=user1&run=detect_untranslated"
```

* find language links in uploaded HTML files

Find language links in HTML files or tar archives (for example from web crawling) and add metadata to imported files. NOTE: files need to be imported already - otherwise this will not add any information to the database! The additional argument `link_type` specifies the style of the language links to look for. Only a few types for specific websites are implemented!

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/uploads/test.html?uid=user1&run=find_language_links"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/uploads/test.tar?uid=user1&run=find_language_links"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/slot1/user1/uploads/test.tar?uid=user1&run=find_language_links&link_type=vnk"
```




* There is a proof of concept installation of the interactive sentence aligner ISA. The job API can be used to prepare the interface for a particular corpusfile, for example

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/xml/en-fi/12.xml?uid=user&run=setup_isa"
```

This would setup the aligner for the sentence alignemnt file `12.xml` from slot `corpus` and branch `user`. The sentence aligner interface is then (hopefully) available from the repository server at the URL

```
http://servername.pouta.csc.fi/isa/user/corpus/index.php
```

The files can also be uploaded to the repository now and the setup can also be removed. NOTE: With the `remove_isa` command the whole subdirectory for the corpus in the ISA setup will be removed without any further notification! The system uploads a copy of the sentence alignment file to the repository (added `.isa.` in the file name)

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/xml/en-fi/12.xml?uid=user&run=upload_isa"
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/corpus/user/xml/en-fi/12.xml?uid=user&run=remove_isa"
```

TODO: Limit the muber of files a user can open for editing (via group database?)

TODO: Need to support password protection as well (but how - with the same password as the interface ir possible!)


* There is another proof-of-concept interface for editing parallel treebanks. The interface can also be set up for aligned documents with the command `setup_ida`:

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/job/subtest/opus/xml/fi-sv/Adrift.xml?uid=opus&run=setup_ida"
```

TODO: nothing can be done with the annotations yet and automatic word alignment is not yet integrated. There is no check for tree constraints, etc. 


## Changes to the metadata API

* add support for new search conditions: `INCLUDES_` (include string), `REGEX_` (matches regular expression)


## Changes to the import and alignment parameters

* new import parameter: `ImportPara_autoalign = on/off` - automatically detect and align parallel documents (default = on)
* new PDF import mode: `ImportPara_mode = combined` - use pdf2xml for conversion from PDF
* new default sentence splitter: `udpipe` (before it was europarl)
* new default aligner: `hunalign-bisent-cautious` (there is now also `hunalign-cautious` and `hunaign-bisent`)
* language detection now always overrules the language that is found in the path unless the `lang` parameter is set in the importer; this can be set as parameter in import requests and file uploads, see the example below

```
$LETSMT_CONNECT -X PUT "$LETSMT_URL/storage/slot1/user1/uploads/pdf/D2.1.pdf?uid=user1&action=import&lang=en" --form payload=@D2.1.pdf 
```


If `autoalign` is off the system will still try to find parallel documents and the result will be stored in the metadata for each monolingual corpus file. The key is `align-candidate` and all candidates can be found by issuing this query on the specific slot (`slot1` in this example):

```
$LETSMT_CONNECT -X GET "$LETSMT_URL/metadata/slot1/user1?ENDS_WITH_align-candidates=xml&uid=user1&type=recursive&action=list_all"
```

You can also run this command for specific subtrees of the repository, for example English files only:

```
$LETSMT_CONNECT -X GET "$LETSMT_URL/metadata/slot1/user1/xml/en?ENDS_WITH_align-candidates=xml&uid=user1&type=recursive&action=list_all"
```

* changes in fuzzy matching of corpus files when looking for translated documents: this is done via String::Approx now and is on by default (AlignPara_search_parallel = similar); old AlignPara_search_parallel_* parameters have no effect



