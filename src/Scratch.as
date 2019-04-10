/*
 * Scratch Project Editor and Player
 * Copyright (C) 2014 Massachusetts Institute of Technology
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

// Scratch.as
// John Maloney, September 2009
//
// This is the top-level application.

package {
import blocks.*;

import by.blooddy.crypto.image.JPEGEncoder;
import by.blooddy.crypto.serialization.JSON;

import com.adobe.images.JPGEncoder;
import com.adobe.utils.StringUtil;

import extensions.ExtensionDevManager;
import extensions.ExtensionManager;

import flash.display.*;
import flash.events.*;
import flash.external.ExternalInterface;
import flash.geom.Point;
import flash.geom.Rectangle;
import flash.net.*;
import flash.system.*;
import flash.text.*;
import flash.utils.*;

import interpreter.*;

import logging.Log;
import logging.LogEntry;
import logging.LogLevel;

import mx.utils.URLUtil;

import render3d.DisplayObjectContainerIn3D;

import scratch.*;

import svgeditor.tools.SVGTool;

import translation.*;

import ui.*;
import ui.media.*;
import ui.parts.*;

import uiwidgets.*;

import util.*;

import watchers.ListWatcher;


public class Scratch extends Sprite {

	// Version
	public static const versionString:String = 'v571';
	public static var app:Scratch; // static reference to the app, used for debugging

	// Display modes
	public var hostProtocol:String = 'http';
	public var editMode:Boolean; // true when project editor showing, false when only the player is showing
	public var isOffline:Boolean; // true when running as an offline (i.e. stand-alone) app
	public var isSmallPlayer:Boolean; // true when displaying as a scaled-down player (e.g. in search results)
	public var stageIsContracted:Boolean; // true when the stage is half size to give more space on small screens
	public var isIn3D:Boolean;
	public var render3D:DisplayObjectContainerIn3D;
	public var isArmCPU:Boolean;
	public var jsEnabled:Boolean = false; // true when the SWF can talk to the webpage
	public var ignoreResize:Boolean = false; // If true, temporarily ignore resize events.
	public var isExtensionDevMode:Boolean = true; // If true, run in extension development mode (as on ScratchX)
	public var isMicroworld:Boolean = false;

	public var presentationScale:Number;
	
	// Runtime
	public var runtime:ScratchRuntime;
	public var interp:Interpreter;
	public var extensionManager:ExtensionManager;
	public var server:Server;
	public var gh:GestureHandler;
	public var projectID:String = '';
	public var projectOwner:String = '';
	public var projectIsPrivate:Boolean;
	public var oldWebsiteURL:String = '';
	public var loadInProgress:Boolean;
	public var debugOps:Boolean = false;
	public var debugOpCmd:String = '';

	protected var autostart:Boolean;
	private var viewedObject:ScratchObj;
	private var lastTab:String = 'scripts';
	protected var wasEdited:Boolean; // true if the project was edited and autosaved
	private var _usesUserNameBlock:Boolean = false;
	protected var languageChanged:Boolean; // set when language changed

	// UI Elements
	public var playerBG:Shape;
	public var palette:BlockPalette;
	public var scriptsPane:ScriptsPane;
	public var stagePane:ScratchStage;
	public var mediaLibrary:MediaLibrary;
	public var lp:LoadProgress;
	public var cameraDialog:CameraDialog;

	// UI Parts
	public var libraryPart:LibraryPart;
	protected var topBarPart:TopBarPart;
	protected var stagePart:StagePart;
	private var tabsPart:TabsPart;
	protected var scriptsPart:ScriptsPart;
	public var imagesPart:ImagesPart;
	public var soundsPart:SoundsPart;
	public const tipsBarClosedWidth:int = 17;
	
	//用户信息
	public var user_id:String="";
	public var class_id:String="";
	public var uuid:String = UUID.create();
	public var project_name:String;
	public var logger:Log = new Log(16);

	public function Scratch() {
		SVGTool.setStage(stage);
		loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, uncaughtErrorHandler);
		app = this;

		// This one must finish before most other queries can start, so do it separately
		determineJSAccess();
	}

	protected function determineJSAccess():void {
		if (externalInterfaceAvailable()) {
			try {
				externalCall('function(){return true;}', jsAccessDetermined);
				return; // wait for callback
			}
			catch (e:Error) {
			}
		}
		jsAccessDetermined(false);
	}

	private function jsAccessDetermined(result:Boolean):void {
		jsEnabled = result;
		initialize();
	}

	protected function initialize():void {
		isOffline = !URLUtil.isHttpURL(loaderInfo.url);
		hostProtocol = URLUtil.getProtocol(loaderInfo.url);

		isExtensionDevMode = (loaderInfo.parameters['extensionDevMode'] == 'true');
		isExtensionDevMode = true;
		isMicroworld = (loaderInfo.parameters['microworldMode'] == 'true');

		checkFlashVersion();
		initServer();

		stage.align = StageAlign.TOP_LEFT;
		stage.scaleMode = StageScaleMode.NO_SCALE;
		stage.frameRate = 30;

		if (stage.hasOwnProperty('color')) {
			// Stage doesn't have a color property on Air 2.6, and Linux throws if you try to set it anyway.
			stage['color'] = CSS.backgroundColor();
		}

		Block.setFonts(10, 9, true, 0); // default font sizes
		Block.MenuHandlerFunction = BlockMenus.BlockMenuHandler;
		CursorTool.init(this);
		app = this;

		stagePane = getScratchStage();
		gh = new GestureHandler(this, (loaderInfo.parameters['inIE'] == 'true'));
		initInterpreter();
		initRuntime();
		initExtensionManager();
		Translator.initializeLanguageList();

		playerBG = new Shape(); // create, but don't add
		addParts();

		server.getSelectedLang(Translator.setLanguageValue);


		stage.addEventListener(MouseEvent.MOUSE_DOWN, gh.mouseDown);
		stage.addEventListener(MouseEvent.MOUSE_MOVE, gh.mouseMove);
		stage.addEventListener(MouseEvent.MOUSE_UP, gh.mouseUp);
		stage.addEventListener(MouseEvent.MOUSE_WHEEL, gh.mouseWheel);
		stage.addEventListener('rightClick', gh.rightMouseClick);

		stage.addEventListener(KeyboardEvent.KEY_UP, runtime.keyUp);
		stage.addEventListener(KeyboardEvent.KEY_DOWN, keyDown); // to handle escape key
		stage.addEventListener(Event.ENTER_FRAME, step);
		stage.addEventListener(Event.RESIZE, onResize);

		setEditMode(startInEditMode());
		if (loaderInfo.parameters["showOnly"])
		{
			setEditMode(loaderInfo.parameters["showOnly"] != "true");
		}
		if (editMode) 
		{
			runtime.installNewProject();
		} else {			
			runtime.installEmptyProject();
		}
		
		
		//读取用户信息
		if (loaderInfo.parameters["uid"]){
			user_id = loaderInfo.parameters["uid"];
			class_id = loaderInfo.parameters['cid'];
			//user_name = loaderInfo.parameters["username"];
		}
		
		if(user_id == "" || user_id == "undefined"){
			DialogBox.notify('提示','您还没有登录，云端功能将无法使用哦~', stage);
			user_id = "";
		}
				
		
		fixLayout();
		//Analyze.collectAssets(0, 119110);
		//Analyze.checkProjects(56086, 64220);
		//Analyze.countMissingAssets();

		handleStartupParameters();
		// 默认语言
		Translator.setLanguage("zh-cn");
		languageChanged = true;
		
		//初始化默认项目
		var project_url:String = loaderInfo.parameters["project_url"];
		if(project_url != "undefined" && project_url != "" && project_url != null){
			project_name = loaderInfo.parameters['project_name'];
			log(LogLevel.DEBUG,'init project',{project:project_url});
			loadSingleGithubURL(project_url);
		}
		preloadEncoder();
		
		logMessage("user_id", user_id);
		logMessage("project_name", project_name);
		logMessage("project_url", project_url);
		 
		externalCall("initialized", null);
		app.log(LogLevel.TRACK,"初始化完成，当前占用内存(MB)",System.totalMemory / 1024 / 1024);
	}

	//预加载MP4编码插件
	private function preloadEncoder() : void
	{
		var url:URLRequest = null;
		var loader:Loader = null;
		var con:LoaderContext = null;
		if(new Server().URLs["mp4"] || new Server().URLs["mp4"] != "null")
		{
			url = new URLRequest(new Server().URLs["mp4"] + "FW_SWFBridge_ffmpeg.swf?v=24");
			loader = new Loader();
			con = new LoaderContext(false,new ApplicationDomain(null),null);
			var onError:Function = function(e:Event):void
			{
				app.jsThrowError("load mp4 encode module error: " + e.toString());
				this.mp4encode = false;
			};
			loader.addEventListener(ErrorEvent.ERROR,onError);
			loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR,onError);
			loader.addEventListener(IOErrorEvent.IO_ERROR,onError);
			loader.addEventListener(AsyncErrorEvent.ASYNC_ERROR,onError);
			loader.load(url,con);
		}
	}
	
	protected function handleStartupParameters():void {
		setupExternalInterface(false);
		jsEditorReady();
	}
	
	//注册接口
	protected function setupExternalInterface(oldWebsitePlayer:Boolean):void {
		if (!jsEnabled) return;

		addExternalCallback('ASloadExtension', extensionManager.loadRawExtension);
		addExternalCallback('ASextensionCallDone', extensionManager.callCompleted);
		addExternalCallback('ASextensionReporterDone', extensionManager.reporterCompleted);
		addExternalCallback('AScreateNewProject', createNewProjectScratchX);
		addExternalCallback("loadProject", loadSingleGithubURL);
		addExternalCallback("submitProject", submitProject);

		if (isExtensionDevMode) {
			addExternalCallback('ASloadGithubURL', loadGithubURL);
			addExternalCallback('ASloadBase64SBX', loadBase64SBX);
			addExternalCallback('ASsetModalOverlay', setModalOverlay);
		}
	}
	
	public function alert(msg:String):void{
		externalCall('alert', null, msg);
	}

	protected function jsEditorReady():void {
		if (jsEnabled) {
			externalCall('JSeditorReady', function (success:Boolean):void {
				if (!success) jsThrowError('Calling JSeditorReady() failed.');
			});
		}
	}

	//在线加载项目
	private function loadSingleGithubURL(url:String, name:String="", cid:String=""):void {
		var index:int = url.indexOf('?');
		if (index > 0) {
			url = url.slice(0, index);
		}			
		index = url.lastIndexOf('/');
		if (index > 0) {
			url = url.slice(0, index) + escape(url.slice(index));
			uuid = url.slice(index + 1, url.length);
			if(uuid.length == 36){
				uuid = uuid;
			}else{
				uuid = UUID.create();
			}
		}
		url = url + "?v=" + Math.random();
		
		log(LogLevel.DEBUG,'尝试载入网络项目',{url:url, uuid:uuid});
		function handleComplete(e:Event):void {	
			runtime.installProjectFromData(sbxLoader.data);
			var newProjectName:String = url;
			if (name != ""){ 
				newProjectName = name
			} else {
				newProjectName="未命名"
			}
			setProjectName(newProjectName);
			stagePane.info.name = newProjectName;
			externalCall('projectLoaded', null);			
		}
		
		
		function onCallServerError(url:String, event:ErrorEvent):void {
			Scratch.app.log(LogLevel.WARNING, 'Failed server request', {event: event, url: url});
			removeLoadProgressBox();
			if (event is SecurityErrorEvent) {
				var urlPathStart:int = url.indexOf('/', 10);
				var policyFileURL:String = url.substr(0, urlPathStart) + '/crossdomain.xml?cb=' + Math.random();
				Security.loadPolicyFile(policyFileURL);
				Scratch.app.log(LogLevel.WARNING, 'Reloading policy file', {policy: policyFileURL, initiator: url});
			}
		}
		
		function handleError(e:ErrorEvent):void {
			onCallServerError(url, e);
			jsThrowError('Failed to load SBX: ' + e.toString());
			alert("项目加载失败");
			//DialogBox.notify('错误','加载项目失败', stage);
			removeLoadProgressBox();
		}
		
		var fileExtension:String = url.substr(url.lastIndexOf('.')).toLowerCase();
		if (fileExtension == '.js') {
			externalCall('ScratchExtensions.loadExternalJS', null, url);
			return;
		}
		
		// Otherwise assume it's a project (SB2, SBX, etc.)
		addLoadProgressBox("加载中……");
		loadInProgress = true;
		var request:URLRequest = new URLRequest(url);
		var sbxLoader:URLLoader = new URLLoader(request);
		sbxLoader.dataFormat = URLLoaderDataFormat.BINARY;
		sbxLoader.addEventListener(Event.COMPLETE, handleComplete);
		sbxLoader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, handleError);
		sbxLoader.addEventListener(IOErrorEvent.IO_ERROR, handleError);
		sbxLoader.addEventListener(ProgressEvent.PROGRESS, function (event:ProgressEvent):void{
			var percent:* = event.bytesLoaded / event.bytesTotal;
			lp.setProgress(percent);
		});
		sbxLoader.load(request);
	}

	private var pendingExtensionURLs:Array;
	private function loadGithubURL(urlOrArray:*):void {
		if (!isExtensionDevMode) return;

		var url:String;
		var urlArray:Array = urlOrArray as Array;
		if (urlArray) {
			var urlCount:int = urlArray.length;
			var extensionURLs:Array = [];
			var projectURL:String;
			var index:int;

			// Filter URLs: allow at most one project file, and wait until it loads before loading extensions.
			for (index = 0; index < urlCount; ++index) {
				url = StringUtil.trim(unescape(urlArray[index]));
				if (StringUtil.endsWith(url.toLowerCase(), '.js')) {
					extensionURLs.push(url);
				}
				else if (url.length > 0) {
					if (projectURL) {
						jsThrowError("Ignoring extra project URL: " + projectURL);
					}
					projectURL = StringUtil.trim(url);
				}
			}
			if (projectURL) {
				pendingExtensionURLs = extensionURLs;
				loadSingleGithubURL(projectURL);
				// warning will be shown later
			}
			else {
				urlCount = extensionURLs.length;
				for (index = 0; index < urlCount; ++index) {
					loadSingleGithubURL(extensionURLs[index]);
				}
				externalCall('JSshowWarning');
			}
		}
		else {
			url = urlOrArray as String;
			loadSingleGithubURL(url);
			externalCall('JSshowWarning');
		}
	}

	private function loadBase64SBX(base64:String):void {
		var sbxData:ByteArray = Base64Encoder.decode(base64);
		app.setProjectName('');
		runtime.installProjectFromData(sbxData);
	}

	protected function initTopBarPart():void {
		topBarPart = new TopBarPart(this);
	}

	protected function initScriptsPart():void {
		scriptsPart = new ScriptsPart(this);
	}

	protected function initImagesPart():void {
		imagesPart = new ImagesPart(this);
	}

	protected function initInterpreter():void {
		interp = new Interpreter(this);
	}

	protected function initRuntime():void {
		runtime = new ScratchRuntime(this, interp);
	}

	protected function initExtensionManager():void {
		if (isExtensionDevMode) {
			extensionManager = new ExtensionDevManager(this);
		}
		else {
			extensionManager = new ExtensionManager(this);
		}
	}

	protected function initServer():void {
		server = new Server();
	}

	public function showTip(tipName:String):void {
	}

	public function closeTips():void {
	}

	public function reopenTips():void {
	}

	public function tipsWidth():int {
		return 0;
	}

	protected function startInEditMode():Boolean {
		return isOffline || isExtensionDevMode;
	}

	public function getMediaLibrary(type:String, whenDone:Function):MediaLibrary {
		return new MediaLibrary(this, type, whenDone);
	}

	public function getMediaPane(app:Scratch, type:String):MediaPane {
		return new MediaPane(app, type);
	}

	public function getScratchStage():ScratchStage {
		return new ScratchStage();
	}

	public function getPaletteBuilder():PaletteBuilder {
		return new PaletteBuilder(this);
	}

	private function uncaughtErrorHandler(event:UncaughtErrorEvent):void {
		if (event.error is Error) {
			var error:Error = event.error as Error;
			logException(error);
		}
		else if (event.error is ErrorEvent) {
			var errorEvent:ErrorEvent = event.error as ErrorEvent;
			log(LogLevel.ERROR, errorEvent.toString());
		}
	}

	// All other log...() methods funnel to this one
	public function log(severity:String, messageKey:String, extraData:Object = null):LogEntry {
		return logger.log(severity, messageKey, extraData);
	}

	// Log an Error object generated by an exception
	public function logException(e:Error):void {
		log(LogLevel.ERROR, e.toString());
	}

	// Shorthand for log(LogLevel.ERROR, ...)
	public function logMessage(msg:String, extra_data:Object = null):void {
		log(LogLevel.ERROR, msg, extra_data);
	}

	public function loadProjectFailed():void {
		loadInProgress = false;
	}

	public function jsThrowError(s:String):void {
		// Throw the given string as an error in the browser. Errors on the production site are logged.
		var errorString:String = 'SWF Error: ' + s;
		log(LogLevel.WARNING, errorString);
		if (jsEnabled) {
			externalCall('JSthrowError', null, errorString);
		}
	}

	protected function checkFlashVersion():void {
		SCRATCH::allow3d {
			if (Capabilities.playerType != "Desktop" || Capabilities.version.indexOf('IOS') === 0) {
				var versionString:String = Capabilities.version.substr(Capabilities.version.indexOf(' ') + 1);
				var versionParts:Array = versionString.split(',');
				var majorVersion:int = parseInt(versionParts[0]);
				var minorVersion:int = parseInt(versionParts[1]);
				if ((majorVersion > 11 || (majorVersion == 11 && minorVersion >= 7))
					&& !isArmCPU && Capabilities.cpuArchitecture == 'x86') {
					render3D = new DisplayObjectContainerIn3D();
					render3D.setStatusCallback(handleRenderCallback);
					return;
				}
			}
		}

		render3D = null;
	}

	SCRATCH::allow3d
	protected function handleRenderCallback(enabled:Boolean):void {
		if (!enabled) {
			go2D();
			render3D = null;
		}
		else {
			for (var i:int = 0; i < stagePane.numChildren; ++i) {
				var spr:ScratchSprite = (stagePane.getChildAt(i) as ScratchSprite);
				if (spr) {
					spr.clearCachedBitmap();
					spr.updateCostume();
					spr.applyFilters();
				}
			}
			stagePane.clearCachedBitmap();
			stagePane.updateCostume();
			stagePane.applyFilters();
		}
	}

	public function clearCachedBitmaps():void {
		for (var i:int = 0; i < stagePane.numChildren; ++i) {
			var spr:ScratchSprite = (stagePane.getChildAt(i) as ScratchSprite);
			if (spr) spr.clearCachedBitmap();
		}
		stagePane.clearCachedBitmap();

		// unsupported technique that seems to force garbage collection
		try {
			new LocalConnection().connect('foo');
			new LocalConnection().connect('foo');
		} catch (e:Error) {
		}
	}

	SCRATCH::allow3d
	public function go3D():void {
		if (!render3D || isIn3D) return;

		var i:int = stagePart.getChildIndex(stagePane);
		stagePart.removeChild(stagePane);
		render3D.setStage(stagePane, stagePane.penLayer);
		stagePart.addChildAt(stagePane, i);
		isIn3D = true;
	}

	SCRATCH::allow3d
	public function go2D():void {
		if (!render3D || !isIn3D) return;

		var i:int = stagePart.getChildIndex(stagePane);
		stagePart.removeChild(stagePane);
		render3D.setStage(null, null);
		stagePart.addChildAt(stagePane, i);
		isIn3D = false;
		for (i = 0; i < stagePane.numChildren; ++i) {
			var spr:ScratchSprite = (stagePane.getChildAt(i) as ScratchSprite);
			if (spr) {
				spr.clearCachedBitmap();
				spr.updateCostume();
				spr.applyFilters();
			}
		}
		stagePane.clearCachedBitmap();
		stagePane.updateCostume();
		stagePane.applyFilters();
	}

	private var debugRect:Shape;

	public function showDebugRect(r:Rectangle):void {
		// Used during debugging...
		var p:Point = stagePane.localToGlobal(new Point(0, 0));
		if (!debugRect) debugRect = new Shape();
		var g:Graphics = debugRect.graphics;
		g.clear();
		if (r) {
			g.lineStyle(2, 0xFFFF00);
			g.drawRect(p.x + r.x, p.y + r.y, r.width, r.height);
			addChild(debugRect);
		}
	}

	public function strings():Array {
		return [
			'a copy of the project file on your computer.',
			'Project not saved!', 'Save now', 'Not saved; project did not load.',
			'Save project?', 'Don\'t save',
			'Save now', 'Saved',
			'Revert', 'Undo Revert', 'Reverting...',
			'Throw away all changes since opening this project?',
		];
	}

	public function viewedObj():ScratchObj {
		return viewedObject;
	}

	public function stageObj():ScratchStage {
		return stagePane;
	}

	public function projectName():String {
		return stagePart.projectName();
	}

	public function highlightSprites(sprites:Array):void {
		libraryPart.highlight(sprites);
	}

	public function refreshImageTab(fromEditor:Boolean):void {
		imagesPart.refresh(fromEditor);
	}

	public function refreshSoundTab():void {
		soundsPart.refresh();
	}

	public function selectCostume():void {
		imagesPart.selectCostume();
	}

	public function selectSound(snd:ScratchSound):void {
		soundsPart.selectSound(snd);
	}

	public function clearTool():void {
		CursorTool.setTool(null);
		topBarPart.clearToolButtons();
	}

	public function tabsRight():int {
		return tabsPart.x + tabsPart.w;
	}

	public function enableEditorTools(flag:Boolean):void {
		imagesPart.editor.enableTools(flag);
	}

	public function get usesUserNameBlock():Boolean {
		return _usesUserNameBlock;
	}

	public function set usesUserNameBlock(value:Boolean):void {
		_usesUserNameBlock = value;
		stagePart.refresh();
	}

	public function updatePalette(clearCaches:Boolean = true):void {
		// Note: updatePalette() is called after changing variable, list, or procedure
		// definitions, so this is a convenient place to clear the interpreter's caches.
		if (isShowing(scriptsPart)) scriptsPart.updatePalette();
		if (clearCaches) runtime.clearAllCaches();
	}

	public function setProjectName(s:String):void {
		for (;;) {
			if (StringUtil.endsWith(s, '.sb')) s = s.slice(0, -3);
			else if (StringUtil.endsWith(s, '.sb2')) s = s.slice(0, -4);
			else if (StringUtil.endsWith(s, '.sbx')) s = s.slice(0, -4);
			else break;
		}
		stagePart.setProjectName(s);
	}

	protected var wasEditing:Boolean;

	public function setPresentationMode(enterPresentation:Boolean):void {
		if (stagePart.isInPresentationMode() != enterPresentation) {
			presentationModeWasChanged(enterPresentation);
		}
	}

	public function presentationModeWasChanged(enterPresentation:Boolean):void {
		if (enterPresentation) {
			wasEditing = editMode;
			if (wasEditing) {
				setEditMode(false);
				if (jsEnabled) externalCall('tip_bar_api.hide');
			}
		} else {
			if (wasEditing) {
				setEditMode(true);
				if (jsEnabled) externalCall('tip_bar_api.show');
			}
		}
		if (isOffline) {
			stage.displayState = enterPresentation ? StageDisplayState.FULL_SCREEN_INTERACTIVE : StageDisplayState.NORMAL;
		}
		for each (var o:ScratchObj in stagePane.allObjects()) o.applyFilters();

		if (lp) fixLoadProgressLayout();
		stagePart.presentationModeWasChanged(enterPresentation);
		stagePane.updateCostume();
		SCRATCH::allow3d {
			if (isIn3D) render3D.onStageResize();
		}
	}

	private function keyDown(evt:KeyboardEvent):void {
		// Escape stops drag operations
		if (!evt.shiftKey && evt.charCode == 27) {
			gh.escKeyDown();
		}
		// Escape exists presentation mode.
		else if ((evt.charCode == 27) && stagePart.isInPresentationMode()) {
			setPresentationMode(false);
		}
		// Handle enter key
//		else if(evt.keyCode == 13 && !stage.focus) {
//			stagePart.playButtonPressed(null);
//			evt.preventDefault();
//			evt.stopImmediatePropagation();
//		}
		// Handle ctrl-m and toggle 2d/3d mode
		else if (evt.ctrlKey && evt.charCode == 109) {
			SCRATCH::allow3d {
				isIn3D ? go2D() : go3D();
			}
			evt.preventDefault();
			evt.stopImmediatePropagation();
		}
		else {
			runtime.keyDown(evt);
		}
	}

	private function setSmallStageMode(flag:Boolean):void {
		stageIsContracted = flag;
		stagePart.updateRecordingTools();
		fixLayout();
		libraryPart.refresh();
		tabsPart.refresh();
		stagePane.applyFilters();
		stagePane.updateCostume();
	}

	public function projectLoaded():void {
		removeLoadProgressBox();
		System.gc();
		if (autostart) runtime.startGreenFlags(true);
		loadInProgress = false;
		saveNeeded = false;

		// translate the blocks of the newly loaded project
		for each (var o:ScratchObj in stagePane.allObjects()) {
			o.updateScriptsAfterTranslation();
		}

		if (jsEnabled && isExtensionDevMode) {
			if (pendingExtensionURLs) {
				loadGithubURL(pendingExtensionURLs);
				pendingExtensionURLs = null;
			}
			externalCall('JSprojectLoaded');
		}
	}

	public function resetPlugin(whenDone:Function):void {
		if (jsEnabled) {
			externalCall('ScratchExtensions.resetPlugin');
		}
		if (whenDone != null) {
			whenDone();
		}
	}

	protected function step(e:Event):void {
		// Step the runtime system and all UI components.
		gh.step();
		runtime.stepRuntime();
		Transition.step(null);
		stagePart.step();
		libraryPart.step();
		scriptsPart.step();
		imagesPart.step();
	}

	public function updateSpriteLibrary(sortByIndex:Boolean = false):void {
		libraryPart.refresh()
	}

	public function updateTopBar():void {
		topBarPart.refresh();
	}

	public function threadStarted():void {
		stagePart.threadStarted()
	}

	public function selectSprite(obj:ScratchObj):void {
		if (isShowing(imagesPart)) imagesPart.editor.shutdown();
		if (isShowing(soundsPart)) soundsPart.editor.shutdown();
		viewedObject = obj;
		libraryPart.refresh();
		tabsPart.refresh();
		if (isShowing(imagesPart)) {
			imagesPart.refresh();
		}
		if (isShowing(soundsPart)) {
			soundsPart.currentIndex = 0;
			soundsPart.refresh();
		}
		if (isShowing(scriptsPart)) {
			scriptsPart.updatePalette();
			scriptsPane.viewScriptsFor(obj);
			scriptsPart.updateSpriteWatermark();
		}
	}

	public function setTab(tabName:String):void {
		if (isShowing(imagesPart)) imagesPart.editor.shutdown();
		if (isShowing(soundsPart)) soundsPart.editor.shutdown();
		hide(scriptsPart);
		hide(imagesPart);
		hide(soundsPart);
		if (!editMode) return;
		if (tabName == 'images') {
			show(imagesPart);
			imagesPart.refresh();
		} else if (tabName == 'sounds') {
			soundsPart.refresh();
			show(soundsPart);
		} else if (tabName && (tabName.length > 0)) {
			tabName = 'scripts';
			scriptsPart.updatePalette();
			scriptsPane.viewScriptsFor(viewedObject);
			scriptsPart.updateSpriteWatermark();
			show(scriptsPart);
		}
		show(tabsPart);
		show(stagePart); // put stage in front
		tabsPart.selectTab(tabName);
		lastTab = tabName;
		if (saveNeeded) // save project when switching tabs, if needed (but NOT while loading!)
			setSaveNeeded(true); 
	}

	public function installStage(newStage:ScratchStage):void {
		var showGreenflagOverlay:Boolean = shouldShowGreenFlag();
		stagePart.installStage(newStage, showGreenflagOverlay);
		selectSprite(newStage);
		libraryPart.refresh();
		setTab('scripts');
		scriptsPart.resetCategory();
		wasEdited = false;
	}

	protected function shouldShowGreenFlag():Boolean {
		return !(autostart || editMode);
	}

	protected function addParts():void {
		initTopBarPart();
		stagePart = getStagePart();
		libraryPart = getLibraryPart();
		tabsPart = new TabsPart(this);
		initScriptsPart();
		initImagesPart();
		soundsPart = new SoundsPart(this);
		addChild(topBarPart);
		addChild(stagePart);
		addChild(libraryPart);
		addChild(tabsPart);
	}

	protected function getStagePart():StagePart {
		return new StagePart(this);
	}

	protected function getLibraryPart():LibraryPart {
		return new LibraryPart(this);
	}

	public function fixExtensionURL(javascriptURL:String):String {
		return javascriptURL;
	}

	// -----------------------------
	// UI Modes and Resizing
	//------------------------------
	public function setEditMode(newMode:Boolean):void {
		Menu.removeMenusFrom(stage);
		editMode = newMode;
		if (editMode) {
			interp.showAllRunFeedback();
			hide(playerBG);
			show(topBarPart);
			show(libraryPart);
			show(tabsPart);
			setTab(lastTab);
			stagePart.hidePlayButton();
			runtime.edgeTriggersEnabled = true;
		} else {
			addChildAt(playerBG, 0); // behind everything
			playerBG.visible = false;
			hide(topBarPart);
			hide(libraryPart);
			hide(tabsPart);
			setTab(null); // hides scripts, images, and sounds
		}
		stagePane.updateListWatchers();
		show(stagePart); // put stage in front
		fixLayout();
		stagePart.refresh();
	}

	protected function hide(obj:DisplayObject):void {
		if (obj.parent) obj.parent.removeChild(obj)
	}

	protected function show(obj:DisplayObject):void {
		addChild(obj)
	}

	protected function isShowing(obj:DisplayObject):Boolean {
		return obj.parent != null
	}

	public function onResize(e:Event):void {
		if (!ignoreResize) fixLayout();
	}

	public function fixLayout():void {
		var w:int = stage.stageWidth;
		var h:int = stage.stageHeight - 1; // fix to show bottom border...

		w = Math.ceil(w / scaleX);
		h = Math.ceil(h / scaleY);

		updateLayout(w, h);
	}
	
	public function updateRecordingTools(t:Number):void {
		stagePart.updateRecordingTools(t);
	}
	
	public function removeRecordingTools():void {
		stagePart.removeRecordingTools();
	}
	
	public function refreshStagePart():void {
		stagePart.refresh();
	}

	protected function updateLayout(w:int, h:int):void {
		topBarPart.x = 0;
		topBarPart.y = 0;
		topBarPart.setWidthHeight(w, 28);

		var extraW:int = 2;
		var extraH:int = stagePart.computeTopBarHeight() + 1;
		if (editMode) {
			// adjust for global scale (from browser zoom)

			if (stageIsContracted) {
				stagePart.setWidthHeight(240 + extraW, 180 + extraH, 0.5);
			} else {
				stagePart.setWidthHeight(480 + extraW, 360 + extraH, 1);
			}
			stagePart.x = 5;
			stagePart.y = isMicroworld ? 5 : topBarPart.bottom() + 5;
			fixLoadProgressLayout();
		} else {
			drawBG();
			var pad:int = (w > 550) ? 16 : 0; // add padding for full-screen mode
			var scale:Number = Math.min((w - extraW - pad) / 480, (h - extraH - pad) / 360);
			scale = Math.max(0.01, scale);
			var scaledW:int = Math.floor((scale * 480) / 4) * 4; // round down to a multiple of 4
			scale = scaledW / 480;
			presentationScale = scale;
			var playerW:Number = (scale * 480) + extraW;
			var playerH:Number = (scale * 360) + extraH;
			stagePart.setWidthHeight(playerW, playerH, scale);
			stagePart.x = int((w - playerW) / 2);
			stagePart.y = int((h - playerH) / 2);
			fixLoadProgressLayout();
			return;
		}
		libraryPart.x = stagePart.x;
		libraryPart.y = stagePart.bottom() + 18;
		libraryPart.setWidthHeight(stagePart.w, h - libraryPart.y);

		tabsPart.x = stagePart.right() + 5;
		if (!isMicroworld) {
			tabsPart.y = topBarPart.bottom() + 5;
			tabsPart.fixLayout();
		}
		else
			tabsPart.visible = false;

		// the content area shows the part associated with the currently selected tab:
		var contentY:int = tabsPart.y + 27;
		if (!isMicroworld)
			w -= tipsWidth();
		updateContentArea(tabsPart.x, contentY, w - tabsPart.x - 6, h - contentY - 5, h);
	}

	protected function updateContentArea(contentX:int, contentY:int, 
			contentW:int, contentH:int, fullH:int):void {
		imagesPart.x = soundsPart.x = scriptsPart.x = contentX;
		imagesPart.y = soundsPart.y = scriptsPart.y = contentY;
		imagesPart.setWidthHeight(contentW, contentH);
		soundsPart.setWidthHeight(contentW, contentH);
		scriptsPart.setWidthHeight(contentW, contentH);

		if (mediaLibrary) mediaLibrary.setWidthHeight(topBarPart.w, fullH);
		if (frameRateGraph) {
			frameRateGraph.y = stage.stageHeight - frameRateGraphH;
			addChild(frameRateGraph); // put in front
		}

		SCRATCH::allow3d {
			if (isIn3D) render3D.onStageResize();
		}
	}

	private function drawBG():void {
		var g:Graphics = playerBG.graphics;
		g.clear();
		g.beginFill(0);
		g.drawRect(0, 0, stage.stageWidth, stage.stageHeight);
	}

	private var modalOverlay:Sprite;

	public function setModalOverlay(enableOverlay:Boolean):void {
		var currentlyEnabled:Boolean = !!modalOverlay;
		if (enableOverlay != currentlyEnabled) {
			if (enableOverlay) {
				function eatEvent(event:MouseEvent):void {
					event.stopImmediatePropagation();
					event.stopPropagation();
				}

				modalOverlay = new Sprite();
				modalOverlay.graphics.beginFill(CSS.backgroundColor_ScratchX, 0.8);
				modalOverlay.graphics.drawRect(0, 0, stage.width, stage.height);
				modalOverlay.addEventListener(MouseEvent.CLICK, eatEvent);
				modalOverlay.addEventListener(MouseEvent.MOUSE_DOWN, eatEvent);
				if (SCRATCH::allow3d) { // TODO: use a better flag or rename this one
					// These events are only available in flash 11.2 and above.
					modalOverlay.addEventListener(MouseEvent.RIGHT_CLICK, eatEvent);
					modalOverlay.addEventListener(MouseEvent.RIGHT_MOUSE_DOWN, eatEvent);
					modalOverlay.addEventListener(MouseEvent.MIDDLE_CLICK, eatEvent);
					modalOverlay.addEventListener(MouseEvent.MIDDLE_MOUSE_DOWN, eatEvent);
				}
				stage.addChild(modalOverlay);
			}
			else {
				stage.removeChild(modalOverlay);
				modalOverlay = null;
			}
		}
	}
	
	//点击logo事件
	public function logoButtonPressed(b:IconButton):void {
//		var _newURL:URLRequest=new URLRequest("http://www.213.name");
//		var _fangshi:String="_blank";
//		navigateToURL(_newURL,_fangshi);
//		
//		if (isExtensionDevMode) {
//			externalCall('showPage', null, 'home');
//		}
	}

	// -----------------------------
	// Translations utilities
	//------------------------------

	public function translationChanged():void {
		// The translation has changed. Fix scripts and update the UI.
		// directionChanged is true if the writing direction (e.g. left-to-right) has changed.
		for each (var o:ScratchObj in stagePane.allObjects()) {
			o.updateScriptsAfterTranslation();
		}
		var uiLayer:Sprite = app.stagePane.getUILayer();
		for (var i:int = 0; i < uiLayer.numChildren; ++i) {
			var lw:ListWatcher = uiLayer.getChildAt(i) as ListWatcher;
			if (lw) lw.updateTranslation();
		}
		topBarPart.updateTranslation();
		stagePart.updateTranslation();
		libraryPart.updateTranslation();
		tabsPart.updateTranslation();
		updatePalette(false);
		imagesPart.updateTranslation();
		soundsPart.updateTranslation();
	}

	// -----------------------------
	// Menus
	//------------------------------
	
	public function showHelpMenu(b:*):void {
		var m:Menu = new Menu(null,'帮助',CSS.topBarColor(),28);
		m.addItem('关于',showAboutDialog);
//		if(user_token!=""){
//			m.addItem('反馈',saveScreenshot);
//		}
		m.showOnStage(stage, b.x, topBarPart.bottom() - 1);
	}
	
	
	public function showFileMenu(b:*):void {
		var m:Menu = new Menu(null, 'File', CSS.topBarColor(), 28);
		m.addItem('New', createNewProject);
		m.addLine();

		// Derived class will handle this
		addFileMenuItems(b, m);

		m.showOnStage(stage, b.x, topBarPart.bottom() - 1);
	}
	
	public function stopVideo(b:*):void {
		runtime.stopVideo();
	}

	protected function addFileMenuItems(b:*, m:Menu):void {
		if(user_id != ""){
			m.addItem('从云端载入项目',projectList);
			m.addItem('保存项目到云端',saveProject);
			m.addItem('邀请好友一起玩',shareProject);
			if (runtime.recording || runtime.ready==ReadyLabel.COUNTDOWN 
				|| runtime.ready==ReadyLabel.READY) {
				m.addItem('停止录像', runtime.stopVideo);
			} else {
				m.addItem('录屏炫耀交作业', runtime.exportToVideo);
			}
		}
		m.addLine();
		m.addItem('从电脑加载项目', runtime.selectProjectFile);
		m.addItem('保存项目到电脑', exportProjectToFile);
		m.addItem('修改项目名称',changeProjectTitle);		
		if (canUndoRevert()) {
			m.addLine();
			m.addItem('Undo Revert', undoRevert);
		} else if (canRevert()) {
			m.addLine();
			m.addItem('Revert', revertToOriginalProject);
		}

		if (b.lastEvent.shiftKey) {
			m.addItem('录制成视频', runtime.exportToVideo);
			m.addItem('保存项目摘要', saveSummary);
			m.addItem('显示版本信息', showVersionDetails);
			m.addItem('从URL加载项目',loadProject);
		}
		if (b.lastEvent.shiftKey && jsEnabled) {
			m.addLine();
			m.addItem('导入JS实验拓展模块', function ():void {
				function loadJSExtension(dialog:DialogBox):void {
					var url:String = dialog.getField('URL').replace(/^\s+|\s+$/g, '');
					if (url.length == 0) return;
					externalCall('ScratchExtensions.loadExternalJS', null, url);
				}

				var d:DialogBox = new DialogBox(loadJSExtension);
				d.addTitle('导入JS实验拓展模块');
				d.addField('URL', 120);
				d.addAcceptCancelButtons('载入');
				d.showOnStage(app.stage);
			});
		}
	}

	public function showEditMenu(b:*):void {
		var m:Menu = new Menu(null, 'More', CSS.topBarColor(), 28);
		m.addItem('Undelete', runtime.undelete, runtime.canUndelete());
		m.addLine();
		m.addItem('Small stage layout', toggleSmallStage, true, stageIsContracted);
		m.addItem('Turbo mode', toggleTurboMode, true, interp.turboMode);
		addEditMenuItems(b, m);
		var p:Point = b.localToGlobal(new Point(0, 0));
		m.showOnStage(stage, b.x, topBarPart.bottom() - 1);
	}

	protected function addEditMenuItems(b:*, m:Menu):void {
		m.addLine();
		m.addItem('编辑块颜色', editBlockColors);
	}

	protected function editBlockColors():void {
		var d:DialogBox = new DialogBox();
		d.addTitle('编辑块颜色');
		d.addWidget(new BlockColorEditor());
		d.addButton('关闭', d.cancel);
		d.showOnStage(stage, true);
	}

	protected function canExportInternals():Boolean {
		return false;
	}

	private function showAboutDialog():void {
		DialogBox.notify("关于",
				'\n杭州尼巴信息技术有限公司' +
				'\nHangzhou Niba Information Technology Co.,Ltd.', stage);
	}

	protected function createNewProjectAndThen(callback:Function = null):void {
		function clearProject():void {
			startNewProject('', '');
			setProjectName('未命名');
			uuid = UUID.create();
			topBarPart.refresh();
			stagePart.refresh();
			if (callback != null) callback();
		}

		saveProjectAndThen(clearProject);
	}

	protected function createNewProject(ignore:* = null):void {
		createNewProjectAndThen();
	}

	protected function createNewProjectScratchX(jsCallback:Array):void {
		createNewProjectAndThen(function():void {
			externalCallArray(jsCallback);
		});
	}
	
	public function projectList():void{
		externalCall('projectList');
	}

	public function loadProject():void{
		
		function load(dialog:DialogBox):void {
			var url:String = dialog.getField('url');
			loadSingleGithubURL(url);
		}
		var d:DialogBox = new DialogBox(load);
		d.addTitle('从URL加载项目');
		d.addField('url', 500);
		d.addAcceptCancelButtons('确定');
		d.showOnStage(app.stage);		
	}
	
	public function myUrlEncode(str:String,code:String):String
	{
		var stringresult:String = "";
		var byte:ByteArray =new ByteArray();
		byte.writeMultiByte(str,code);
		for (var i:int; i<byte.length; i++)
		{
			stringresult +=  escape(String.fromCharCode(byte[i]));
		}
		return stringresult;
	}
	
	public function shareProject():void{
		saveProject();
		externalCall("shareProject", null, uuid);
	}
	
	//保存项目
	public function saveProject(fromJS:Boolean = false, saveCallback:Function = null):void{
		if (projectName() == "" || projectName() == "未命名"){
			changeProjectTitle(saveProject);
			return;
		}
		checkUUID();
		Scratch.app.log(LogLevel.TRACK, "正在上传项目", 
			{user_id: app.user_id, uuid: app.uuid, projname: projectName()});
		//externalCall("fileUploading",null,1);
		function squeakSoundsConverted():void {
			scriptsPane.saveScripts(false);
			var projectType:String = extensionManager.hasExperimentalExtensions() ? '.sbx' : '.sb2';
			var defaultName:String = StringUtil.trim(projectName());
			defaultName = ((defaultName.length > 0) ? defaultName : 'project') + projectType;
			var zipData:ByteArray = projIO.encodeProjectAsZipFile(stagePane);
			
			var posturl:String = new Server().URLs['siteAPI'] + "upload";;
			var parameters:Object = new Object();  
			parameters["uuid"] = app.uuid;
			parameters["ftype"] = 2;//2-项目文件
			parameters["project"] = projectName();
			
			var requestData:URLRequest = new URLRequest(posturl);
			requestData.data = UploadPostHelper.getPostData(uuid, zipData, "file", parameters); 
			requestData.method = URLRequestMethod.POST;
			requestData.contentType = 'multipart/form-data; boundary=' + UploadPostHelper.getBoundary();
			requestData.requestHeaders = [new URLRequestHeader("Cache-Control", "no-cache")];
				
			var loader:URLLoader = new URLLoader(); 
			loader.dataFormat = URLLoaderDataFormat.BINARY;
			
			loader.addEventListener(Event.COMPLETE, function (e:Event):void {
				//var res:* = by.blooddy.crypto.serialization.JSON.decode(loader.data);
				externalCall("projectUploaded",null, uuid);
				//log(LogLevel.TRACK,"响应",loader.data);
				//var response:* = by.blooddy.crypto.serialization.JSON.decode(loader.data);
				DialogBox.close("提示","上传成功",null,"关闭");
			});
			
			saveScreenshot();
			
			var onError:Function = function (e:Event) : void
			{
				jsThrowError('Failed upload: ' + e.toString());
				DialogBox.close("错误", "请检查你的网络链接并重试\n"+e, null, "重试",
					app.stage, saveProject, null, null, true);
			}
			loader.addEventListener(ErrorEvent.ERROR, onError);
			loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
			loader.addEventListener(IOErrorEvent.IO_ERROR, onError);
			loader.addEventListener(AsyncErrorEvent.ASYNC_ERROR, onError);
			loader.load(requestData);
		}
		
		function fileSaved(e:Event):void {
			if (!fromJS) setProjectName(e.target.name);
			if (isExtensionDevMode) {
				// Some versions of the editor think of this as an "export" and some think of it as a "save"
				saveNeeded = false;
			}
			if (saveCallback != null) saveCallback();
		}
		
		if (loadInProgress) return;
		var projIO:ProjectIO = new ProjectIO(this);
		projIO.convertSqueakSounds(stagePane, squeakSoundsConverted);
		
	}
	
	public function saveScreenshot():void{
		Scratch.app.log(LogLevel.TRACK, "正在上传缩略图", 
			{user_id: app.user_id, uuid: app.uuid, projname: projectName()});
		//缩略图
		var stage:* = stagePane;
		var data:BitmapData = new BitmapData(stage.width,stage.height,true,0);
		data.draw(stage);
		var jpg_encoder:* = new JPGEncoder(50);
		var jpg:* = jpg_encoder.encode(data);
		var url:String = new Server().URLs['siteAPI'] + "upload";
		var parameters:Object = new Object();  
		parameters["uuid"] = app.uuid;
		parameters["ftype"] = 1;
		parameters["project"] = projectName();
		var requestData:URLRequest = new URLRequest(url); 
		requestData.data = UploadPostHelper.getPostData(uuid, jpg, "file", parameters);
		requestData.contentType = 'multipart/form-data; boundary=' + UploadPostHelper.getBoundary();
		requestData.method = URLRequestMethod.POST;
		requestData.requestHeaders = [new URLRequestHeader("Cache-Control", "no-cache")];
		var loader_jpg:URLLoader = new URLLoader();
		loader_jpg.dataFormat = URLLoaderDataFormat.BINARY;
		loader_jpg.addEventListener(Event.COMPLETE, function (e:Event):void {
//			externalCall("fileUploaded",null,0,url);
//			log(LogLevel.TRACK,"响应",loader_jpg.data);
		});
		
		loader_jpg.load(requestData);
	}
	
	public function submitProject(fromJS:Boolean = false, saveCallback:Function = null):void{		
//		function rename(dialog:DialogBox):void {
//			var name:String = dialog.getField('用户名').replace(/^\s+|\s+$/g, '');
//			var project_name:String = dialog.getField('作品名').replace(/^\s+|\s+$/g, '');
//			if(name.length>0&&project_name.length>0){
//				if (project_name != stagePane.info.name){
//					stagePane.info.name = project_name;
//					setProjectName(project_name);
//					uuid = UUID.create();
//				}
//				
//				app.user_id = name;
//				saveProject();
//			}else{
//				DialogBox.close("错误", "输入错误", null, "关闭", app.stage, null, null, null, true);
//				return;
//			}
//			saveProject();
//		}
//		var d:DialogBox = new DialogBox(rename);
//		d.addTitle('提交作品：');
//		d.addField('用户名', 100, app.user_id);
//		d.addField('作品名', 100, app.projectName());
//		d.addAcceptCancelButtons('确定');
//		d.showOnStage(app.stage);
		runtime.exportToVideo();
	}
	
	protected function saveProjectAndThen(postSaveAction:Function = null):void {
		// Give the user a chance to save their project, if needed, then call postSaveAction.
		function doNothing():void {
		}

		function cancel():void {
			d.cancel();
		}

		function proceedWithoutSaving():void {
			d.cancel();
			postSaveAction()
		}

		function save():void {
			d.cancel();
			exportProjectToFile(false, postSaveAction);
		}

		if (postSaveAction == null) postSaveAction = doNothing;
		if (!saveNeeded) {
			postSaveAction();
			return;
		}
		var d:DialogBox = new DialogBox();
		d.addTitle('Save project?');
		d.addButton('Save', save);
		d.addButton('Don\'t save', proceedWithoutSaving);
		d.addButton('Cancel', cancel);
		d.showOnStage(stage);
	}

	//导出项目到本地
	public function exportProjectToFile(fromJS:Boolean = false, saveCallback:Function = null):void {
		function squeakSoundsConverted():void {
			scriptsPane.saveScripts(false);
			var projectType:String = extensionManager.hasExperimentalExtensions() ? '.sbx' : '.sb2';
			var defaultName:String = StringUtil.trim(projectName());
			defaultName = ((defaultName.length > 0) ? defaultName : 'project') + projectType;
			var zipData:ByteArray = projIO.encodeProjectAsZipFile(stagePane);
			var file:FileReference = new FileReference();
			file.addEventListener(Event.COMPLETE, fileSaved);
			file.save(zipData, fixFileName(defaultName));
		}

		function fileSaved(e:Event):void {
			if (!fromJS) setProjectName(e.target.name);
			if (isExtensionDevMode) {
				// Some versions of the editor think of this as an "export" and some think of it as a "save"
				saveNeeded = false;
			}
			if (saveCallback != null) saveCallback();
		}

		if (loadInProgress) return;
		var projIO:ProjectIO = new ProjectIO(this);
		projIO.convertSqueakSounds(stagePane, squeakSoundsConverted);
	}
	
	public function checkUUID():void{
		var url:String = new Server().URLs['siteAPI']+"check?uuid="+app.uuid;
		var requestData:URLRequest = new URLRequest(url); 
		var loader:URLLoader = new URLLoader();
		requestData.method = URLRequestMethod.GET;
		
		var onError:Function = function (e:Event) : void
		{
			jsThrowError('Failed check uuid: '+ url + "\n" + e.toString());
		}
		loader.addEventListener(ErrorEvent.ERROR, onError);
		loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onError);
		loader.addEventListener(IOErrorEvent.IO_ERROR, onError);
		loader.addEventListener(AsyncErrorEvent.ASYNC_ERROR, onError);
		
		loader.addEventListener(Event.COMPLETE, function (e:Event):void {
			log(LogLevel.TRACK,"响应",loader.data);
			var res:* = by.blooddy.crypto.serialization.JSON.decode(loader.data);
			log(LogLevel.DEBUG,'check uuid',{res:res});
			if("err" in res){
				uuid = UUID.create();
				log(LogLevel.DEBUG,'create uuid',{new_uuid:uuid});
			}
		});
		loader.load(requestData);
	}
	
	//重命名项目
	public function changeProjectTitle(cb:* = null):void{
		function rename(dialog:DialogBox):void {
			var name:String = dialog.getField('项目名').replace(/^\s+|\s+$/g, '');
			stagePane.info.name = name;
			setProjectName(name);
			//uuid = UUID.create();
			if(cb != null){
				cb();
			}
		}
		var d:DialogBox = new DialogBox(rename);
		d.addTitle('给作品起个名字吧');
		d.addField('项目名', 120,projectName());
		d.addAcceptCancelButtons('确定');
		d.showOnStage(app.stage);
		
	}

	public static function fixFileName(s:String):String {
		// Replace illegal characters in the given string with dashes.
		const illegal:String = '\\/:*?"<>|%';
		var result:String = '';
		for (var i:int = 0; i < s.length; i++) {
			var ch:String = s.charAt(i);
			if ((i == 0) && ('.' == ch)) ch = '-'; // don't allow leading period
			result += (illegal.indexOf(ch) > -1) ? '-' : ch;
		}
		return result;
	}

	public function saveSummary():void {
		var name:String = (projectName() || "project") + ".txt";
		var file:FileReference = new FileReference();
		file.save(stagePane.getSummary(), fixFileName(name));
	}

	public function toggleSmallStage():void {
		setSmallStageMode(!stageIsContracted);
	}

	public function toggleTurboMode():void {
		interp.turboMode = !interp.turboMode;
		stagePart.refresh();
	}

	public function handleTool(tool:String, evt:MouseEvent):void {
	}

	public function showBubble(text:String, x:* = null, y:* = null, width:Number = 0):void {
		if (x == null) x = stage.mouseX;
		if (y == null) y = stage.mouseY;
		gh.showBubble(text, Number(x), Number(y), width);
	}

	// TODO: calculate field width for up to 40 hex digits of CSS.normalTextFont
	protected const kGitHashFieldWidth:int = 7 * 41;
	protected function makeVersionDetailsDialog():DialogBox {
		var d:DialogBox = new DialogBox();
		d.addTitle('Version Details');
		d.addField('GPU enabled', kGitHashFieldWidth, SCRATCH::allow3d);
		d.addField('scratch-flash', kGitHashFieldWidth, SCRATCH::revision);
		return d;
	}

	protected function showVersionDetails():void {
		var versionDetailsBox:DialogBox = makeVersionDetailsDialog();
		versionDetailsBox.addButton('OK', versionDetailsBox.accept);
		versionDetailsBox.showOnStage(stage);
	}

	// -----------------------------
	// Project Management and Sign in
	//------------------------------

	public function setLanguagePressed(b:IconButton):void {
		function setLanguage(lang:String):void {
			Translator.setLanguage(lang);
			languageChanged = true;
		}

		if (Translator.languages.length == 0) return; // empty language list
		var m:Menu = new Menu(setLanguage, 'Language', CSS.topBarColor(), 28);
		if (b.lastEvent.shiftKey) {
			m.addItem('导入语言包');
			m.addItem('设置字体大小');
			m.addLine();
		}
		for each (var entry:Array in Translator.languages) {
			m.addItem(entry[1], entry[0]);
		}
		var p:Point = b.localToGlobal(new Point(0, 0));
		m.showOnStage(stage, b.x, topBarPart.bottom() - 1);
	}

	public function startNewProject(newOwner:String, newID:String):void {
		runtime.installNewProject();
		projectOwner = newOwner;
		projectID = newID;
		projectIsPrivate = true;
	}

	// -----------------------------
	// Save status
	//------------------------------

	public var saveNeeded:Boolean;

	public function setSaveNeeded(saveNow:Boolean = false):void {
		saveNow = false;
		// Set saveNeeded flag and update the status string.
		saveNeeded = true;
		if (!wasEdited) saveNow = true; // force a save on first change
		clearRevertUndo();
	}

	protected function clearSaveNeeded():void {
		// Clear saveNeeded flag and update the status string.
		function twoDigits(n:int):String {
			return ((n < 10) ? '0' : '') + n
		}

		saveNeeded = false;
		wasEdited = true;
	}

	// -----------------------------
	// Project Reverting
	//------------------------------

	protected var originalProj:ByteArray;
	private var revertUndo:ByteArray;

	public function saveForRevert(projData:ByteArray, isNew:Boolean, onServer:Boolean = false):void {
		originalProj = projData;
		revertUndo = null;
	}

	protected function doRevert():void {
		runtime.installProjectFromData(originalProj, false);
	}

	protected function revertToOriginalProject():void {
		function preDoRevert():void {
			revertUndo = new ProjectIO(Scratch.app).encodeProjectAsZipFile(stagePane);
			doRevert();
		}

		if (!originalProj) return;
		DialogBox.confirm('Throw away all changes since opening this project?', stage, preDoRevert);
	}

	protected function undoRevert():void {
		if (!revertUndo) return;
		runtime.installProjectFromData(revertUndo, false);
		revertUndo = null;
	}

	protected function canRevert():Boolean {
		return originalProj != null
	}

	protected function canUndoRevert():Boolean {
		return revertUndo != null
	}

	private function clearRevertUndo():void {
		revertUndo = null
	}

	public function addNewSprite(spr:ScratchSprite, showImages:Boolean = false, atMouse:Boolean = false):void {
		var c:ScratchCostume, byteCount:int;
		for each (c in spr.costumes) {
			if (!c.baseLayerData) c.prepareToSave()
			byteCount += c.baseLayerData.length;
		}
		if (!okayToAdd(byteCount)) return; // not enough room
		spr.objName = stagePane.unusedSpriteName(spr.objName);
		spr.indexInLibrary = 1000000; // add at end of library
		spr.setScratchXY(int(200 * Math.random() - 100), int(100 * Math.random() - 50));
		if (atMouse) spr.setScratchXY(stagePane.scratchMouseX(), stagePane.scratchMouseY());
		stagePane.addChild(spr);
		spr.updateCostume();
		selectSprite(spr);
		setTab(showImages ? 'images' : 'scripts');
		setSaveNeeded(true);
		libraryPart.refresh();
		for each (c in spr.costumes) {
			if (ScratchCostume.isSVGData(c.baseLayerData)) c.setSVGData(c.baseLayerData, false);
		}
	}

	public function addSound(snd:ScratchSound, targetObj:ScratchObj = null):void {
		if (snd.soundData && !okayToAdd(snd.soundData.length)) return; // not enough room
		if (!targetObj) targetObj = viewedObj();
		snd.soundName = targetObj.unusedSoundName(snd.soundName);
		targetObj.sounds.push(snd);
		setSaveNeeded(true);
		if (targetObj == viewedObj()) {
			soundsPart.selectSound(snd);
			setTab('sounds');
		}
	}

	public function addCostume(c:ScratchCostume, targetObj:ScratchObj = null):void {
		if (!c.baseLayerData) c.prepareToSave();
		if (!okayToAdd(c.baseLayerData.length)) return; // not enough room
		if (!targetObj) targetObj = viewedObj();
		c.costumeName = targetObj.unusedCostumeName(c.costumeName);
		targetObj.costumes.push(c);
		targetObj.showCostumeNamed(c.costumeName);
		setSaveNeeded(true);
		if (targetObj == viewedObj()) setTab('images');
	}

	public function okayToAdd(newAssetBytes:int):Boolean {
		// Return true if there is room to add an asset of the given size.
		// Otherwise, return false and display a warning dialog.
		const assetByteLimit:int = 50 * 1024 * 1024; // 50 megabytes
		var assetByteCount:int = newAssetBytes;
		for each (var obj:ScratchObj in stagePane.allObjects()) {
			for each (var c:ScratchCostume in obj.costumes) {
				if (!c.baseLayerData) c.prepareToSave();
				assetByteCount += c.baseLayerData.length;
			}
			for each (var snd:ScratchSound in obj.sounds) assetByteCount += snd.soundData.length;
		}
		if (assetByteCount > assetByteLimit) {
			var overBy:int = Math.max(1, (assetByteCount - assetByteLimit) / 1024);
			DialogBox.notify(
					'Sorry!',
					'Adding that media asset would put this project over the size limit by ' + overBy + ' KB\n' +
					'Please remove some costumes, backdrops, or sounds before adding additional media.',
					stage);
			return false;
		}
		return true;
	}

	// -----------------------------
	// Flash sprite (helps connect a sprite on the stage with a sprite library entry)
	//------------------------------

	public function flashSprite(spr:ScratchSprite):void {
		function doFade(alpha:Number):void {
			box.alpha = alpha
		}

		function deleteBox():void {
			if (box.parent) {
				box.parent.removeChild(box)
			}
		}

		var r:Rectangle = spr.getVisibleBounds(this);
		var box:Shape = new Shape();
		box.graphics.lineStyle(3, CSS.overColor, 1, true);
		box.graphics.beginFill(0x808080);
		box.graphics.drawRoundRect(0, 0, r.width, r.height, 12, 12);
		box.x = r.x;
		box.y = r.y;
		addChild(box);
		Transition.cubic(doFade, 1, 0, 0.5, deleteBox);
	}

	// -----------------------------
	// Download Progress
	//------------------------------

	public function addLoadProgressBox(title:String):void {
		removeLoadProgressBox();
		lp = new LoadProgress();
		lp.setTitle(title);
		stage.addChild(lp);
		fixLoadProgressLayout();
	}

	public function removeLoadProgressBox():void {
		if (lp && lp.parent) lp.parent.removeChild(lp);
		lp = null;
	}

	private function fixLoadProgressLayout():void {
		if (!lp) return;
		var p:Point = stagePane.localToGlobal(new Point(0, 0));
		lp.scaleX = stagePane.scaleX;
		lp.scaleY = stagePane.scaleY;
		lp.x = int(p.x + ((stagePane.width - lp.width) / 2));
		lp.y = int(p.y + ((stagePane.height - lp.height) / 2));
	}

	// -----------------------------
	// Frame rate readout (for use during development)
	//------------------------------

	private var frameRateReadout:TextField;
	private var firstFrameTime:int;
	private var frameCount:int;

	protected function addFrameRateReadout(x:int, y:int, color:uint = 0):void {
		frameRateReadout = new TextField();
		frameRateReadout.autoSize = TextFieldAutoSize.LEFT;
		frameRateReadout.selectable = false;
		frameRateReadout.background = false;
		frameRateReadout.defaultTextFormat = new TextFormat(CSS.font, 12, color);
		frameRateReadout.x = x;
		frameRateReadout.y = y;
		addChild(frameRateReadout);
		frameRateReadout.addEventListener(Event.ENTER_FRAME, updateFrameRate);
	}

	private function updateFrameRate(e:Event):void {
		frameCount++;
		if (!frameRateReadout) return;
		var now:int = getTimer();
		var msecs:int = now - firstFrameTime;
		if (msecs > 500) {
			var fps:Number = Math.round((1000 * frameCount) / msecs);
			frameRateReadout.text = fps + ' fps (' + Math.round(msecs / frameCount) + ' msecs)';
			firstFrameTime = now;
			frameCount = 0;
		}
	}

	// TODO: Remove / no longer used
	private const frameRateGraphH:int = 150;
	private var frameRateGraph:Shape;
	private var nextFrameRateX:int;
	private var lastFrameTime:int;

	private function addFrameRateGraph():void {
		addChild(frameRateGraph = new Shape());
		frameRateGraph.y = stage.stageHeight - frameRateGraphH;
		clearFrameRateGraph();
		stage.addEventListener(Event.ENTER_FRAME, updateFrameRateGraph);
	}

	public function clearFrameRateGraph():void {
		var g:Graphics = frameRateGraph.graphics;
		g.clear();
		g.beginFill(0xFFFFFF);
		g.drawRect(0, 0, stage.stageWidth, frameRateGraphH);
		nextFrameRateX = 0;
	}

	private function updateFrameRateGraph(evt:*):void {
		var now:int = getTimer();
		var msecs:int = now - lastFrameTime;
		lastFrameTime = now;
		var c:int = 0x505050;
		if (msecs > 40) c = 0xE0E020;
		if (msecs > 50) c = 0xA02020;

		if (nextFrameRateX > stage.stageWidth) clearFrameRateGraph();
		var g:Graphics = frameRateGraph.graphics;
		g.beginFill(c);
		var barH:int = Math.min(frameRateGraphH, msecs / 2);
		g.drawRect(nextFrameRateX, frameRateGraphH - barH, 1, barH);
		nextFrameRateX++;
	}

	// -----------------------------
	// Camera Dialog
	//------------------------------

	public function openCameraDialog(savePhoto:Function):void {
		closeCameraDialog();
		cameraDialog = new CameraDialog(savePhoto);
		cameraDialog.fixLayout();
		cameraDialog.x = (stage.stageWidth - cameraDialog.width) / 2;
		cameraDialog.y = (stage.stageHeight - cameraDialog.height) / 2;
		addChild(cameraDialog);
	}

	public function closeCameraDialog():void {
		if (cameraDialog) {
			cameraDialog.closeDialog();
			cameraDialog = null;
		}
	}

	// Misc.
	public function createMediaInfo(obj:*, owningObj:ScratchObj = null):MediaInfo {
		return new MediaInfo(obj, owningObj);
	}

	static public function loadSingleFile(fileLoaded:Function, filter:FileFilter = null):void {
		function fileSelected(event:Event):void {
			if (fileList.fileList.length > 0) {
				var file:FileReference = FileReference(fileList.fileList[0]);
				file.addEventListener(Event.COMPLETE, fileLoaded);
				file.load();
			}
		}

		var fileList:FileReferenceList = new FileReferenceList();
		fileList.addEventListener(Event.SELECT, fileSelected);
		try {
			// Ignore the exception that happens when you call browse() with the file browser open
			fileList.browse(filter != null ? [filter] : null);
		} catch (e:*) {
		}
	}

	// -----------------------------
	// External Interface abstraction
	//------------------------------

	public function externalInterfaceAvailable():Boolean {
		return ExternalInterface.available;
	}

	public function externalCall(functionName:String, returnValueCallback:Function = null, ...args):void {
		args.unshift(functionName);
		var retVal:*;
		try {
			retVal = ExternalInterface.call.apply(ExternalInterface, args);
		}
		catch (e:Error)
		{
			logException(e);
			// fall through to below
		}
		if (returnValueCallback != null) {
			returnValueCallback(retVal);
		}
	}

	public function addExternalCallback(functionName:String, closure:Function):void {
		ExternalInterface.addCallback(functionName, closure);
	}

	// jsCallbackArray is: [functionName, arg1, arg2...] where args are optional.
	// TODO: rewrite all versions of externalCall in terms of this
	public function externalCallArray(jsCallbackArray:Array, returnValueCallback:Function = null):void {
		var args:Array = jsCallbackArray.concat(); // clone
		args.splice(1, 0, returnValueCallback);
		externalCall.apply(this, args);
	}
}
}
