module Main where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Trans (liftIO)
import Data.Char (isDigit)
import Graphics.Rendering.Cairo
import Graphics.UI.Gtk
import Graphics.UI.Gtk.Gdk.EventM
import Graphics.UI.Gtk.Poppler.Document
import Graphics.UI.Gtk.Poppler.Annotation
import Graphics.UI.Gtk.Poppler.Page

data Viewer =
            Viewer { viewerArea           :: DrawingArea
                   , viewerDocument       :: Document
                   , viewerScrolledWindow :: ScrolledWindow
                   , viewerCurrentPage    :: Int
                   , viewerPageCount      :: Int
                   , viewerZoom           :: Double }

main :: IO ()
main = do
  initGUI
  window <- windowNew
  vbox   <- vBoxNew False 0
  align  <- createControlPanel vbox
  boxPackStart vbox align PackNatural 10
  containerAdd window vbox
  set window windowParams
  onDestroy window mainQuit
  widgetShowAll window
  mainGUI

createViewerVar :: IO (TVar (Maybe Viewer))
createViewerVar = newTVarIO Nothing

createControlPanel :: VBox -> IO Alignment
createControlPanel vbox = do
  vVar   <- createViewerVar
  align  <- alignmentNew 1 0 0 0
  bbox   <- hButtonBoxNew
  fchb   <- createFileChooserButton
  label  <- labelNew Nothing
  entry  <- entryNew
  scale  <- hScaleNewWithRange 1 200 1
  button <- createViewButton vbox fchb label entry scale vVar
  widgetSetSensitive scale False
  rangeSetValue scale 100
  entry `on` entryActivate $ pageBrowserChanged entry vVar
  scale `on` valueChanged $ pageZoomChanged scale vVar
  containerAdd align bbox
  containerAdd bbox scale
  containerAdd bbox entry
  containerAdd bbox label
  containerAdd bbox fchb
  containerAdd bbox button
  set bbox [buttonBoxLayoutStyle := ButtonboxStart]
  return align

pageBrowserChanged :: Entry -> TVar (Maybe Viewer) -> IO ()
pageBrowserChanged entry viewerVar = do
  text <- entryGetText entry
  when (all isDigit text) (join $ atomically $ action (read text))
    where
      action page =
        readTVar viewerVar >>= \vOpt ->
          let nothingToDo = return (return ())
              go (Viewer area x swin cur nb y)
                | page == cur = nothingToDo
                | page < 1    = return (entrySetText entry "1")
                | page > nb   = return (entrySetText entry (show nb))
                | otherwise   =
                  let newViewer = Viewer area x swin (page - 1) nb y in
                  writeTVar viewerVar (Just newViewer) >>= \_ ->
                    return (widgetQueueDraw area) in
          maybe nothingToDo go vOpt

pageZoomChanged :: HScale -> TVar (Maybe Viewer) -> IO ()
pageZoomChanged scale viewerVar = do
  value <- rangeGetValue scale
  join $ atomically $ action (value / 100)
    where
      action value = do
        (Just v) <- readTVar viewerVar
        let area = viewerArea v
        writeTVar viewerVar (Just v{viewerZoom = value})
        return (widgetQueueDraw area)

windowParams :: [AttrOp Window]
windowParams =
  [windowTitle          := "Dhek PDF Viewer"
  ,windowDefaultWidth   := 800
  ,windowDefaultHeight  := 600
  ,containerBorderWidth := 10]

createFileChooserButton :: IO FileChooserButton
createFileChooserButton = do
  fcb  <- fileChooserButtonNew "Select PDF File" FileChooserActionOpen
  filt <- fileFilterNew
  fileFilterAddPattern filt "*.pdf"
  fileFilterSetName filt "Pdf File"
  fileChooserAddFilter fcb  filt
  return fcb

createViewButton :: VBox
                 -> FileChooserButton
                 -> Label
                 -> Entry
                 -> HScale
                 -> TVar (Maybe Viewer)
                 -> IO Button
createViewButton vbox chooser label entry scale viewerVar = do
  button <- buttonNewWithLabel "View"
  onClicked button (go button)
  return button

  where
    go button = do
      select <- fileChooserGetFilename chooser
      maybe (print "(No Selection)") (makeView button) select

    makeView button filepath = do
      updateViewer filepath viewerVar
      join $ atomically $ action button
      widgetShowAll vbox

    action button =
      readTVar viewerVar >>= \(Just (Viewer _ doc swin cur nPages _)) ->
        return $ do
          let pagesStr   = show nPages
              charLength = length pagesStr
          labelSetText label ("/ " ++ pagesStr)
          entrySetText entry (show (cur +  1))
          entrySetMaxLength entry charLength
          entrySetWidthChars entry charLength
          boxPackStart vbox swin PackGrow 0
          widgetSetSensitive chooser False
          widgetSetSensitive button False
          widgetSetSensitive scale True
          --rect  <- pageRectangleNew
          --annot <- annotTextNew doc rect
          page     <- documentGetPage doc 0
          mappings <- pageGetAnnotMapping page
          let openTheBox (AnnotMapping (PopplerRectangle x x1 y y1) a) = do
                annotGetAnnotType a >>= \typ ->
                  case typ of
                    PopplerAnnotText ->
                      do let annotText = castToAnnotText a
                         --b <- annotMarkupHasPopup annotText
                         --print b
                         annotMarkupSetPopupIsOpen annotText True
                         content <- annotGetContents annotText
                         popup <- windowNewPopup
                         buffer <- textBufferNew Nothing
                         (start, _) <- textBufferGetBounds buffer
                         textBufferInsert buffer start content
                         textView <- textViewNewWithBuffer buffer
                         windowSetDefaultSize popup (truncate (x1 - x)) (truncate (y1 - y))
                         containerAdd popup textView
                         widgetShowAll popup
                         topWidget <- widgetGetToplevel popup
                         (Just (x', y')) <- widgetTranslateCoordinates topWidget popup (truncate x1) (truncate y1)
                         print (x', y')
                         windowMove popup x' y'
                         --containerAdd vbox area
                         --b2 <- annotMarkupGetPopupIsOpen annotText
                         --print b2
                    _  -> print "not a Text annotation"
          mapM_ ((print =<<) . openTheBox) mappings
          --annotSetAnnotFlags annot AnnotFlagPrint
          --flag <- annotGetAnnotFlags annot
          --annotSetContents annot "Hello Annotation !!!"
          --cont  <- annotGetContents annot
          --print (show flag)
          --print cont
          --pageAddAnnot page annot
         -- r <- documentSave doc "file:///home/yoeight/Desktop/Toto2.pdf"
          --print (show r)

createTable :: IO Table
createTable = tableNew 2 2 False

updateViewer :: String -> TVar (Maybe Viewer) -> IO ()
updateViewer filepath var = do
  area <- drawingAreaNew
  doc  <- liftM (\(Just x) -> x) (documentNewFromFile ("file://" ++ filepath) Nothing)
  swin <- scrolledWindowNew Nothing Nothing
  scrolledWindowAddWithViewport swin area
  scrolledWindowSetPolicy swin PolicyAutomatic PolicyAutomatic
  nPages <- documentGetNPages doc
  let viewer = Viewer area  doc swin 0 nPages 1
  atomically $ writeTVar var (Just viewer)
  void $ area `on` exposeEvent $ tryEvent $ viewerDraw var

viewerDraw :: TVar (Maybe Viewer) -> EventM EExpose ()
viewerDraw = liftIO . (go =<<) . readTVarIO
  where
    go (Just (Viewer area doc swin cur _ zoom)) = do
      page  <- documentGetPage doc cur
      frame <- widgetGetDrawWindow area
      (docWidth, docHeight) <- pageGetSize page
      let width  = 760 * zoom
          scaleX = (width / docWidth)
          height = scaleX * docHeight
      widgetSetSizeRequest area (truncate width) (truncate height)
      renderWithDrawable frame (setSourceRGB 1.0 1.0 1.0 >>
                                scale scaleX scaleX      >>
                                pageRender page)
