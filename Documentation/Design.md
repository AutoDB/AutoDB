# AutoDB design 

## Class vs Structs (thinking aloud)

Data is usually modelled with Structs in Swift, but in AutoDB the situation is a mixed bag using both Struct and Class. There are reasons for this. 

Over the years Apple's own guidelines has been to only use Structs when the data is "simple" in some measure, but become more in the line of "use it as much as you can". I think that is a good statement but you have to understand its limits. You cannot have structs if you want to perform modifications elsewhere, like in a frameworks cache. Changes are hard to deal with since Structs (usually) become copies. Structs are faster and more memory efficient, and this shows when creating a lot of objects (imagine having a map with millions of data points, creating and destroying almost for free is a powerful feature). We simply need both of these properties, so how can we solve that? By using both of-course! 

A database table is modelled with Structs, so we can tap into that extra power when we need it. While change-tracking and caching is a property of a Class called Model, which keep the table-struct as a value. Those features are usually only required by a "few" objects, where we are willing to pay this cost. This means we can use the Table inside the Model if we would ever need the benefits of a Struct.  

This separates concerns and makes the modelling easier. The only caveat is that Tables need an identity since Models don't have their own database values. 

### Speed

Structs are a lot faster to create and destruct (destruction costs nothing) since they are on the stack, always copying also makes multi-threading issues impossible, so when you have "bags of data" that doesn't need identity, conflict handling or other more advanced features; Structs are the choice to make.
However, in the normal case you do need those things so using a class and pass around a reference is better. The second reason is that when having more complex data, you don't want to create and destroy, but rather make incremental changes. Then the advantage of Structs diminishes.

### Data is structs

An AutoDB Table is a struct for the performance gains but also since it makes change-tracking much easier. It is truly a "best of both worlds" situation, those that don't want or need resolving identity can just skip the Model class.