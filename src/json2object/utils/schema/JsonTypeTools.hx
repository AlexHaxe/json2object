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

import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
using json2object.utils.TypeTools;

typedef AnonDecls = Map<String, {field:String, expr:Expr}>;

class JsonTypeTools {
#if macro
	inline static function str2Expr (str:String) : Expr {
		return macro $v{str};
	}

	inline static function nullable (ct:ComplexType) : ComplexType {
		return TPath({name: "Null", pack:[], params:[ TPType(ct)], sub:null});
	}

	public static function toExpr(jt:JsonType) : Expr {
		return _toExpr(jt, '', null);
	}

	static function declsToAnonDecl (decls:AnonDecls) : Expr {
		#if haxe4
		return {
			expr:EObjectDecl([ for (k=>v in decls) {field:k, expr:v.expr, quotes:Quoted}]),
			pos:Context.currentPos()
		};
		#else
		return {
			expr:EObjectDecl([ for (value in decls) value]),
			pos:Context.currentPos()
		};
		#end
	}

	static function sort (a:String, b:String) : Int {
		if (a == b) { return 0; }
		return (a > b) ? 1 : -1;
	}

	static function _toExpr(jt:JsonType, descr:String, defaultValue:Null<Expr>) : Expr {
		var decls = new AnonDecls();
		inline function declare(name:String, expr:Expr) {
			decls.set(name, {field:name, expr:expr});
		}

		switch (jt) {
			case JTNull:
				declare("type", macro "null");
			case JTSimple(type):
				declare("type", macro $v{type});
			case JTString(s):
				declare("const", macro $v{s});
			case JTBool(b):
				declare("const_bool", (b) ? macro true : macro false);
			case JTFloat(f):
				declare("const_float", macro $v{f});
			case JTInt(i):
				declare("const_int", macro $v{i});
			case JTObject(properties, rq, defaults):
				declare("type", macro 'object');
				var propertiesDecl = [];
				var keys = [ for (k in properties.keys()) k ];
				keys.sort(sort);
				for (key in keys) {
					propertiesDecl.push({
						expr:EBinop(
							OpArrow,
							macro $v{key},
							_toExpr(properties.get(key), '', defaults.get(key))
						),
						pos:Context.currentPos()
					});
				}
				var propertiesExpr = {expr: EArrayDecl(propertiesDecl), pos: Context.currentPos()};
				declare("properties", propertiesExpr);
				if (rq.length > 0) {
					rq.sort(sort);
					var requiredExpr = {expr:EArrayDecl(rq.map(str2Expr)), pos: Context.currentPos()};
					declare("required", requiredExpr);
				}
				declare("additionalProperties", macro false);
			case JTArray(type):
				declare("type", macro "array");
				declare("items", toExpr(type));
			case JTMap(onlyInt, type):
				declare("type", macro "object");
				if (onlyInt) {
					var patternPropertiesExpr = {
						expr: EArrayDecl([
							{expr:EBinop(OpArrow, macro "/^[-+]?\\d+([Ee][+-]?\\d+)?$/", toExpr(type)), pos:Context.currentPos()}
						]),
						pos: Context.currentPos()
					}
					declare("patternProperties", patternPropertiesExpr);
				}
				else {
					declare("additionalProperties_obj", toExpr(type));
				}
			case JTRef(name):
				declare("ref", str2Expr('#/definitions/'+name));
			case JTAnyOf(types):
				var anyOfExpr = {expr: EArrayDecl(types.map(toExpr)), pos:Context.currentPos()};
				declare("anyOf", anyOfExpr);
			case JTWithDescr(type, descr):
				return _toExpr(type, descr, defaultValue);
		}

		if (descr != '') {
			declare("description", str2Expr(clean(descr)));
		}

		if (defaultValue != null) {
			declare('defaultValue', defaultValue);
		}

		return declsToAnonDecl(decls);
	}

	/**
	 * Clean the doc
	 * 2 new line => 1 new line
	 * 1 new line => 0 new line
	 * all line first non whitespace char is * then remove all first *
	 */
	static function clean (doc:String) : String {
		var lines = [];
		var hasStar = true;
		var start = 0;
		var cursor = 0;
		while (cursor < doc.length) {
			switch (doc.charAt(cursor)) {
				case "\r":
					if (doc.charAt(cursor+1) == "\n") {
						cursor++;
					}
					var line = doc.substring(start, cursor).trim();
					lines.push(line);
					start = cursor + 1;
					if (line.length > 0) {
						hasStar = hasStar && (line.charAt(0) == '*');
					}
				case "\n":
					var line = doc.substring(start, cursor).trim();
					lines.push(line);
					start = cursor + 1;
					if (line.length > 0) {
						hasStar = hasStar && (line.charAt(0) == '*');
					}
				default:
			}
			cursor++;
		}

		var consecutiveNewLine = 0;
		var result = [""];
		var i = -1;
		for (line in lines) {
			line = (hasStar) ? line.substr(1) : line;
			if (line.trim().length == 0) {
				if (i == -1) {
					continue;
				}
				consecutiveNewLine++;
			}
			else {
				if (i == -1) { i = 0; }
				else {
					var curr = result[i];
					if (curr != "" && curr.charAt(curr.length - 1) != " " && line.charAt(0) != " ") {
						line = " " + line;
					}
				}
				result[i] += line;
				consecutiveNewLine = 1;
			}
			if (consecutiveNewLine > 1) {
				result.push('');
				i++;
				consecutiveNewLine = 0;
			}
		}
		return result.join("\n");
	}
#end
}