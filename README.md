# ObjectDecoder: Turn dicts and arrays into structs and classes

This is some code I wrote for Asana that can apply a `Decodable` implementation to a nested collection. For example:

```swift
struct Person: Decodable {
  let name: String
}

let personDict = ["name": "Bob"]

let person = try ObjectDecoder.decode(Person.self, from: personDict)
// -> Person(name: "Bob")
```

Another possible use is to help migrate an old codebase from `JSONSerialization` to `Codable` for HTTP response parsing. You can port parsing code to `Codable` one object at a time, starting deep in the response and working your way out.

```swift
let apiResponse = "{\"data\": {\"person\": {\"name\": \"Bob\"}}}"
let json = try! JSONSerialization.jsonObject(with: apiResponse.data(using: .utf8)!)
let personData = ((json as! NSDictionary)["data"] as! NSDictionary)["person"] as! NSDictionary
let person = try ObjectDecoder.decode(Person.self, from: personData)
```

## Installation

In the interest of getting this code out in public, I skimped on polishing this repo, so you have two options:

**Option 1:** Copy the Swift file into your codebase.  
**Option 2:** Open a pull request adding a `Package.swift` file and moving `ObjectDecoder.swift` to the right place. Then, install using Swift Package Manager. 🙂

## Regarding maintenance

It's not clear to me how many people need this. I'm responsive to pull requests but will not necessarily make updates proactively.
