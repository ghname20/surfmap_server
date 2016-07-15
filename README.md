# surfmap\_server
## A SOAP interface for the surfmapper project

**Surfmapper** is a project designed to keep track of browsing history and visualize it in a node graph.  
The project's main incentive was to handle huge navigation graphs outside of the browser, because otherwise it would hog too much memory.  

This is a SOAP server written in Perl, and it serves SOAP requests and interacts with the surfmap\_storage system.  
It acts as an intermediary between storage and UI.   
This is a multithreaded application capable of deferred syncing of the database to disk, while serving user requests.

Currently I have no time to describe it in detail or work out some installation procedure.

