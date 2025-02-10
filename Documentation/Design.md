# AutoDB design 

## Class vs Structs (thinking aloud)

Data is usually modelled with Structs in Swift, but not in AutoDB. There are reasons for this. 

Over the years Apple's own guidelines has been to only use Structs when the data is "simple" in some measure, but become more in the line of "use it as much as you can". I think that is a good statement but you have to understand its limits. You cannot have structs if you want to perform modifications elsewhere, like in a framework, or in a cache. Those changes will be hard to keep track of since you are usually always making copies of Structs. AutoDB wants to make keeping track of changes easy, and remove as many merge-conflicts as possible and with Structs that is hard - it can be done of course but a better and easier way is to just choose classes. Then we can have the data in one place, with identity, and use references to that - when data is changed it can only be changed in one place and conflicts becomes basically impossible (at least in a local scope).

Apple agrees with this and states "Use classes when you need to control the identity of the data you’re modeling" (when I write this in 2025) [source](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes).

They have said this in the past about when to use Structs:

* The structure’s primary purpose is to encapsulate a few relatively simple data values.
* It is reasonable to expect that the encapsulated values will be copied rather than referenced when you assign or pass around an instance of that structure.
* Any properties stored by the structure are themselves value types, which would also be expected to be copied rather than referenced.

I still think that these are good points also.

### Speed

Structs are a lot faster to create and destruct (destruction costs nothing) since they are on the stack, always copying also makes multi-threading issues impossible, so when you have "bags of data" that doesn't need identity, conflict handling or other more advanced features then why not Structs?
Simple answer is of course that it should be possible, but time is limited. The second reason is that when having more complex data that you don't create over and over; this advantage diminishes. You really need to create objects at a massive scale to notice a difference (which absolutely can happen in certain apps and use-cases). It is however not the common use-case for data you need/want to store in a database. A typical app with just a few different classes and a handful of instantiated objects will never benefit from all the extra complexity that comes with sending around copies of its data. 

### The future of structs

If I had the time there would already be support for Structs since they are faster and can be Sendable. We loose a lot of the other benefits like conflict-resolution and caching, but that may also not be particularly meaningful with Structs. But is it worth it? I actually don't think it will be. It won't be faster in regular use (in certain cases you will be re-fetching from DB over and over to make sure the correct values are used and then it will be much worse), it will have more problems where users might make mistakes that causees data errors (changing a copied Struct). The API will also be clunkier since you must keep track of DB-changes in every place you are using data. It is a lot of extra manual labour and that is something we don't like, do we?
But if you have a table of miljon coordinates to show on a map, you should be able to have Structs to maximize speed. There should be a way to opt in to this even if some automatic aspects gets disregarded and there are more manual labour. 
As of now however, the aim is for the most common use-case. Where the app as complex objects that need to remain unique, never in conflict and changes reflected everywhere in the app without re-fetching (and of course automatic migrations that are lightning fast with auto-caching, etc).
