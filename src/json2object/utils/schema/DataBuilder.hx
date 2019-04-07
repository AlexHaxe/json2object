/*
Copyright (c) 2019 Guillaume Desquesnes, Valentin Lemière

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

package json2object.utils.schema;

#if !macro
class DataBuilder {}
#else
import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import json2object.utils.schema.JsonType;
import json2object.writer.StringUtils;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;
using json2object.utils.schema.JsonTypeTools;
using StringTools;

typedef Definitions = Map<String, JsonType>;

class DataBuilder {

	static var counter:Int = 0;
	private static var writers = new Map<String, Type>();

	private inline static function describe (type:JsonType, descr:Null<String>) {
		return (descr == null) ? type : JTWithDescr(type, descr);
	}

	private static function define(name:String, type:JsonType, definitions:Definitions, doc:Null<String>=null) {
		definitions.set(name, describe(type, doc));
	}

	static function anyOf(t1:JsonType, t2:JsonType) {
		return switch [t1, t2] {
			case [null, t], [t, null]: t;
			case [JTNull, JTAnyOf(v)], [JTAnyOf(v), JTNull] if (v.indexOf(JTNull) != -1): t2;
			case [JTAnyOf(v1), JTAnyOf(v2)]: JTAnyOf(v1.concat(v2));
			case [JTAnyOf(val), t], [t, JTAnyOf(val)]: JTAnyOf(val.concat([t]));
			default: JTAnyOf([t1, t2]);
		}
	}

	static function makeAbstractSchema(type:Type, definitions:Definitions):JsonType {
		var name = type.toString();
		var doc:Null<String> = null;
		switch (type) {
			case TAbstract(_.get()=>t, p):
				var jt:Null<JsonType> = null;
				var from = (t.from.length == 0) ? [{t:t.type, field:null}] : t.from;
				var i = 0;
				for(fromType in from) {
					try {
						var ft = fromType.t.applyTypeParameters(t.params, p);
						var ft = ft.followWithAbstracts();
						jt = anyOf(jt, makeSchema(ft, definitions));
					}
					catch (_:#if (haxe_ver >= 4) Any #else Dynamic #end) {}
				}
				if (jt == null) {
					throw "Abstract "+name+ " has no json representation "+ Context.currentPos();
				}
				define(name, jt, definitions, doc);
				return JTRef(name);
			default:
				throw "Unexpected type "+name;
		}
	}
	static function makeAbstractEnumSchema(type:Type, definitions:Definitions):JsonType {
		var name = type.toString();
		var doc:Null<String> = null;
		switch (type.followWithAbstracts()) {
			case TInst(_.get()=>t, _):
				if (t.module != "String") {
					throw "json2object: Unsupported abstract enum type:"+ name + " " + Context.currentPos();
				}
			case TAbstract(_.get()=>t, _):
				if (t.module != "StdTypes" && (t.name != "Int" && t.name != "Bool" && t.name != "Float")) {
					throw "json2object: Unsupported abstract enum type:"+ name + " " + Context.currentPos();
				}
			default: throw "json2object: Unsupported abstract enum type:"+ name + " " + Context.currentPos();
		}
		var values = new Array<Dynamic>();
		var docs = [];
		var jt = null;

		function handleExpr(expr:TypedExprDef, ?rec:Bool=true) : Dynamic {
			return switch (expr) {
				case TConst(TString(s)): JTString(StringUtils.quote(s));
				case TConst(TNull): JTString(null);
				case TConst(TBool(b)): JTBool(b);
				case TConst(TFloat(f)): JTFloat(f);
				case TConst(TInt(i)): JTInt(i);
				case TCast(c, _) if (rec): handleExpr(c.expr, false);
				default: throw false;
			}
		}
		switch (type) {
			case TAbstract(_.get()=>t, p) :
				doc = t.doc;
				for (field in t.impl.get().statics.get()) {
					if (!field.meta.has(":enum") || !field.meta.has(":impl")) {
						continue;
					}
					if (field.expr() == null) { continue; }
					try {
						jt = anyOf(jt, describe(handleExpr(field.expr().expr), field.doc));
					}
					catch (_:#if (haxe_ver >= 4) Any #else Dynamic #end) {}
				}
			default:
		}

		if (jt == null) {
			throw 'json2object: Abstract enum ${name} has no supported value';
		}
		define(name, jt, definitions, doc);
		return JTRef(name);
	}
	static function makeEnumSchema(type:Type, definitions:Definitions):JsonType {
		var name = type.toString();
		var doc:Null<String> = null;

		var complexProperties = new Map<String, JsonType>();
		var jt = null;
		switch (type) {
			case TEnum(_.get()=>t, p):
				for (n in t.names) {
					var construct = t.constructs.get(n);
					var properties = new Map<String, JsonType>();
					var required = [];
					switch (construct.type) {
						case TEnum(_,_):
							jt = anyOf(jt, describe(JTString(StringUtils.quote(n)), construct.doc));
						case TFun(args,_):
							for (a in args) {
								properties.set(a.name, makeSchema(a.t.applyTypeParameters(t.params, p), definitions));
								if (!a.opt) {
									required.push(a.name);
								}
							}
						default:
							continue;
					}
					jt = anyOf(jt, JTObject([n=>describe(JTObject(properties, required), construct.doc)], [n]));
				}
				doc = t.doc;
			default:
		}
		define(name, jt, definitions, doc);
		return JTRef(name);
	}

	static function makeMapSchema(keyType:Type, valueType:Type, definitions:Definitions):JsonType {
		var name = 'Map<${keyType.toString()}, ${valueType.toString()}>';
		if (definitions.exists(name)) {
			return JTRef(name);
		}
		var onlyInt = switch (keyType) {
			case TInst(_.get()=>t, _):
				if (t.module == "String") {
					false;
				}
				else {
					throw "json2object: Only maps with Int or String keys can be transformed to json, got "+keyType.toString() + " " + Context.currentPos();
				}
			case TAbstract(_.get()=>t, _):
				if (t.module == "StdTypes" && t.name == "Int") {
					true;
				}
				else {
					throw "json2object: Only maps with Int or String keys can be transformed to json, got "+keyType.toString() + " " + Context.currentPos();
				}
			default:
				throw "json2object: Only maps with Int or String keys can be transformed to json, got "+keyType.toString() + " " + Context.currentPos();
		}
		define(name, JTMap(onlyInt, makeSchema(valueType, definitions)), definitions);
		return JTRef(name);
	}
	static function makeObjectSchema(type:Type, name:String, definitions:Definitions) : JsonType {
		var properties = new Map<String, JsonType>();
		var required = new Array<String>();

		var fields:Array<ClassField>;

		var tParams:Array<TypeParameter>;
		var params:Array<Type>;

		var doc:Null<String> = null;

		switch (type) {
			case TAnonymous(_.get()=>t):
				fields = t.fields;
				tParams = [];
				params = [];

			case TInst(_.get()=>t, p):
				fields = [];
				var s = t;
				while (s != null)
				{
					fields = fields.concat(s.fields.get());
					s = s.superClass != null ? s.superClass.t.get() : null;
				}

				tParams = t.params;
				params = p;
				doc = t.doc;

			case _: throw "Unexpected type "+name;
		}


		try {
			define(name, null, definitions); // Protection against recursive types
			for (field in fields) {
				if (field.meta.has(":jignored")) { continue; }
				switch(field.kind) {
					case FVar(r,w):
						if (r == AccCall && w == AccCall && !field.meta.has(":isVar")) {
							continue;
						}

						var f_type = field.type.applyTypeParameters(tParams, params);
						var f_name = field.name;
						for (m in field.meta.extract(":alias")) {
							if (m.params != null && m.params.length == 1) {
								switch (m.params[0].expr) {
									case EConst(CString(s)): f_name = s;
									default:
								}
							}
						}

						var optional = field.meta.has(":optional");
						if (!optional) {
							required.push(f_name);
						}

						properties.set(f_name, describe(makeSchema(f_type, definitions, optional), field.doc));
					default:
				}
			}

			define(name, JTObject(properties, required), definitions, doc);
			return JTRef(name);
		}
		catch (e:#if (haxe_ver >= 4) Any #else Dynamic #end) {
			if (definitions.get(name) == null) {
				definitions.remove(name);
			}
			throw e;
		}
	}

	static function makeSchema(type:Type, definitions:Null<Definitions>, ?name:String=null, ?optional:Bool=false) : JsonType {

		if (name == null) {
			name = type.toString();
		}

		if (definitions.exists(name)) {
			return JTRef(name);
		}

		var schema = switch (type) {
			case TInst(_.get()=>t, p):
				switch (t.module) {
					case "String":
						return JTSimple("string");
					case "Array" if (p.length == 1 && p[0] != null):
						return JTArray(makeSchema(p[0], definitions));
					default:
						makeObjectSchema(type, name, definitions);
				}
			case TAnonymous(_):
				makeObjectSchema(type, name, definitions);
			case TAbstract(_.get()=>t, p):
				if (t.name == "Null") {
					var jt = makeSchema(p[0], definitions);
					return (optional) ? jt : anyOf(JTNull, jt);
				}
				else if (t.module == "StdTypes") {
					switch (t.name) {
						case "Int": return JTSimple("integer");
						case "Float", "Single": JTSimple("number");
						case "Bool": return JTSimple("boolean");
						default: throw "json2object: Schema of "+t.name+" can not be generated " + Context.currentPos();
					}
				}
				else if (t.module == #if (haxe_ver >= 4) "haxe.ds.Map" #else "Map" #end) {
					makeMapSchema(p[0], p[1], definitions);
				}
				else {
					if (t.meta.has(":enum")) {
						makeAbstractEnumSchema(type.applyTypeParameters(t.params, p), definitions);
					}
					else {
						makeAbstractSchema(type.applyTypeParameters(t.params, p), definitions);
					}
				}
			case TEnum(_.get()=>t,p):
				makeEnumSchema(type.applyTypeParameters(t.params, p), definitions);
			case TType(_.get()=>t, p):
				var _tmp = makeSchema(t.type.applyTypeParameters(t.params, p), definitions, name);
				if (t.name != "Null") {
					if (t.doc != null) {
						define(name, describe(definitions.get(name), t.doc), definitions);
					}
					else {
						define(name, definitions.get(name), definitions);
					}
				}
				(t.name == "Null" && !optional) ? anyOf(JTNull, _tmp) : _tmp;
			case TLazy(f):
				makeSchema(f(), definitions);
			default:
				throw "json2object: Json schema can not make a schema for type " + name + " " + Context.currentPos();
		}
		return schema;
	}

	static function format(schema:JsonType, definitions:Definitions) : Expr {
		inline function finishDecl (decl:{field:String, expr:Expr}) #if haxe4 : ObjectField #end {
		#if haxe4
			return {field: decl.field, expr: decl.expr, quotes:Quoted};
		#else
			return decl;
		#end
		}

		var decls = [];
		var schemaExpr:Expr = macro $v{"http://json-schema.org/draft-07/schema#"};
		decls.push(finishDecl({field:JsonTypeTools.registerAlias("$schema"), expr:schemaExpr}));
		var hasDef = definitions.keys().hasNext();
		if (hasDef) {
			var definitionsExpr = {
				expr: EArrayDecl(
					[ for (key in definitions.keys())
						{
							expr: EBinop(
								OpArrow,
								macro $v{key},
								definitions.get(key).toExpr()
							),
							pos: Context.currentPos()
						}
					]
				),
				pos: Context.currentPos()
			};
			decls.push(finishDecl({field: 'definitions', expr: definitionsExpr}));
		}

		switch (schema.toExpr().expr) {
			case EObjectDecl(fields):
				decls = decls.concat(fields);
			default:
		}

		return { expr: EObjectDecl(decls), pos: Context.currentPos()} ;

	}

	static function makeSchemaWriter(c:BaseType, type:Type, base:Type=null) {
		var swriterName = c.name + "_" + (counter++);

		if (writers.exists(swriterName)) {
			return writers.get(swriterName);
		}

		var definitions = new Definitions();
		var obj = format(makeSchema(type, definitions), definitions);
		var schemaWriter = macro class $swriterName {
			public var space:String;
			public function new (space:String='') {
				this.space = space;
			}

			private var _schema : Null<String>;
			public var schema(get,never):String;
			function get_schema () : String {
				if (_schema == null) {
					@:privateAccess {
						_schema = new json2object.JsonWriter<json2object.utils.schema.JsonSchemaType>(true)._write(${obj}, space, 0, true, function () { return '"const": null'; });
					}
				}
				return _schema;
			}
		}
		haxe.macro.Context.defineType(schemaWriter);

		var constructedType = haxe.macro.Context.getType(swriterName);
		writers.set(swriterName, constructedType);
		return haxe.macro.Context.getType(swriterName);
	}

	public static function build() {
		switch (Context.getLocalType()) {
			case TInst(c, [type]):
				return makeSchemaWriter(c.get(), type);
			case _:
				Context.fatalError("json2object: Json schema tools must be a class", Context.currentPos());
				return null;
		}
	}
}
#end
