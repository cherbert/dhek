{-# LANGUAGE ScopedTypeVariables #-}
module Dhek.Action where

import Prelude hiding (foldr, mapM_)
import Control.Applicative (WrappedMonad(..))
import Control.Lens
import Control.Monad (void, when, join)
import Control.Monad.State (execState, evalState, execStateT)
import Control.Monad.Reader (runReaderT, ask)
import Control.Monad.Trans (MonadIO(..))
import Data.Array
import qualified Data.IntMap as I
import Data.IORef (IORef, newIORef, readIORef, modifyIORef, writeIORef)
import Data.Foldable (traverse_, foldMap, foldr, mapM_)
import Data.Maybe (fromJust, isJust, isNothing, maybeToList)
import Data.Monoid (First(..), Sum(..))
import Dhek.Types
import Graphics.Rendering.Cairo
  (Render, setSourceRGB, scale, setLineWidth, rectangle, closePath, stroke, fill)
import Graphics.UI.Gtk
import Graphics.UI.Gtk.Poppler.Document
  (Document, Page, documentNewFromFile, documentGetNPages, documentGetPage)
import Graphics.UI.Gtk.Poppler.Page

zoomValues :: Array Int Double
zoomValues = array (0, 10) values
    where
      values = [(0,  0.125) -- 12.5%
               ,(1,  0.25)  -- 25%
               ,(2,  0.5)   -- 50%
               ,(3,  1.0)   -- 100%
               ,(4,  2.0)   -- 200%
               ,(5,  3.0)   -- 300%
               ,(6,  4.0)   -- 400%
               ,(7,  5.0)   -- 500%
               ,(8,  6.0)   -- 600%
               ,(9,  7.0)   -- 700%
               ,(10, 8.0)]  -- 800%

onPrevState :: Int -> Int -> (Bool, Bool, Int)
onPrevState cur count =
    let newCur = cur - 1 in (newCur - 1 < 1, cur == count, newCur)

onNextState :: Int -> Int -> (Bool, Bool, Int)
onNextState cur count =
    let newCur = cur + 1 in (newCur + 1 > count, cur == 1, newCur)

onNavButton :: (Int -> Int -> (Bool, Bool, Int))
            -> Viewer
            -> (Bool, Bool, Viewer) --decide which button to toggle and the new current page value
onNavButton k v =
    let count = v ^. viewerPageCount
        cur   = v ^. viewerCurrentPage
        (tPrev, tNext, newCur) = k cur count in
    (tPrev, tNext, v & viewerCurrentPage .~ newCur)

saveToBoards :: Save -> Boards
saveToBoards (Save _ xs) = execState (traverse_ go xs) (boardsNew nb)
    where
      nb = length xs

      go (page, rects) = traverse_ (traverse_ (insert page)) rects

      insert page r = do
        boardsState += 1
        id <- use boardsState
        let r' = r & rectId .~ id
        boardsMap.at page.traverse.boardRects.at id ?= r'

resizeRect :: Double -> Double -> Area -> Rect -> Rect
resizeRect dx dy area r = execState (go area) r
    where
      go TOP_LEFT = do
        rectX += dx
        rectY += dy
        rectWidth  -= dx
        rectHeight -= dy
      go TOP = do
        rectY += dy
        rectHeight -= dy
      go TOP_RIGHT = do
        rectY += dy
        rectWidth  += dx
        rectHeight -= dy
      go RIGHT = do
        rectWidth += dx
      go BOTTOM_RIGHT = do
        rectWidth += dx
        rectHeight += dy
      go BOTTOM = do
        rectHeight += dy
      go BOTTOM_LEFT = do
        rectX += dx
        rectWidth -= dx
        rectHeight += dy
      go LEFT = do
        rectX += dx
        rectWidth -= dx

loadPdf :: FilePath -> IO Viewer
loadPdf path = do
  doc   <- fmap fromJust (documentNewFromFile path Nothing)
  nb    <- documentGetNPages doc
  pages <- loadPages doc
  return (Viewer doc pages 1 nb 777 3 1.0 (boardsNew nb))

loadPages :: Document -> IO (Array Int PageItem)
loadPages doc = do
    nb <- documentGetNPages doc
    fmap (array (1,nb)) (traverse go [1..nb])
  where
    go i = do
        page  <- documentGetPage doc (i-1)
        (w,h) <- pageGetSize page
        return (i, PageItem page w h)

drawViewer :: DrawingArea -> ViewerRef -> EventM EExpose ()
drawViewer area = liftIO . go
    where
      go ref = do
        ratio    <- viewerGetRatio ref
        page     <- viewerGetPageItem ref
        rects    <- viewerGetPageRects ref
        ove      <- viewerGetOvered ref
        sel      <- viewerGetSelected ref
        rectSel  <- viewerGetSelection ref
        evRect   <- fmap eventGetRect (viewerGetEvent ref)
        frame    <- widgetGetDrawWindow area
        (fW, fH) <- drawableGetSize frame
        let width  = ratio  * (pageWidth page)
            height = ratio  * (pageHeight page)
        widgetSetSizeRequest area (truncate width) (truncate height)
        renderWithDrawable frame $ do
                   setSourceRGB 1.0 1.0 1.0
                   rectangle 0 0 (fromIntegral fW) (fromIntegral fH)
                   fill
                   scale ratio ratio
                   pageRender (pagePtr page)
                   drawRects 1.0 sel ove rects
                   drawingSel rectSel
                   drawRects 1.0 Nothing evRect evRect

      drawRects th sel ove = mapM_ (drawing th sel ove)

      drawing :: Double -> Maybe Rect -> Maybe Rect -> Rect -> Render ()
      drawing th sel ove r =
          let x = r ^. rectX
              y = r ^. rectY
              h = r ^. rectHeight
              w = r ^. rectWidth
              onSel s
                  | s == r    = setSourceRGB 1.0 0 0
                  | otherwise = return ()
              onOver o
                  | o == r    = setSourceRGB 0.16 0.72 0.92
                  | otherwise = return ()
              step _ = setSourceRGB 0 0 1.0 in
          do setSourceRGB 0 0 1.0
             mapM_ onOver ove
             mapM_ onSel sel
             setLineWidth th
             rectangle x y w h
             closePath
             stroke

      drawingSel = mapM_ go
          where
            go r =
                let x = r ^. rectX
                    y = r ^. rectY
                    h = r ^. rectHeight
                    w = r ^. rectWidth in
                do  setSourceRGB 0 1.0 0
                    setLineWidth 1
                    rectangle x y w h
                    closePath
                    stroke
